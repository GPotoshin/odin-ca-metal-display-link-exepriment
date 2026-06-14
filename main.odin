package main

import "base:intrinsics"
import "base:runtime"
import NS  "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA  "vendor:darwin/QuartzCore"
import CV  "vendor:darwin/CoreVideo"
import "vendor:cgltf"
import "core:fmt"
import "core:math/linalg"
import "core:math"
import "core:strings"

Vertex :: struct #packed {
    position: [3]f32 `attribute(0)`,
    normal:   [3]f32 `attribute(1)`,
}

App :: struct {
    device:   ^MTL.Device,
    layer:    ^CA.MetalLayer,
    queue:    ^MTL.CommandQueue,
    pso:      ^MTL.RenderPipelineState,
    vert_buf: ^MTL.Buffer,
    mvp_buf:  ^MTL.Buffer,
    idx_buf:  ^MTL.Buffer,
    idx_count: u32,
    num_verts: uint,
    depth_state: ^MTL.DepthStencilState,
}
app_state : App

main :: proc() {
    // creating application : not releasing it
    app := NS.Application.sharedApplication()
    app->setActivationPolicy(.Regular)
    delegate := NS.application_delegate_register_and_alloc({
        applicationShouldTerminateAfterLastWindowClosed = proc(^NS.Application) -> NS.BOOL { return true },
    }, "app_delegate", context)
    app->setDelegate(delegate)

    // creating window : not releasing it
    frame := NS.Rect{{0, 0}, {1024, 768}}
    wnd := NS.Window_alloc()
    wnd->initWithContentRect(frame, {.Resizable, .Closable, .Titled}, .Buffered, false)
    wnd->setTitle(NS.AT("Odin Metal ToyCar Viewer"))
    wnd->makeKeyAndOrderFront(nil)
    app->activateIgnoringOtherApps(true)

    // getting device
    app_state.device = MTL.CreateSystemDefaultDevice()
    app_state.layer  = CA.MetalLayer.layer()
    app_state.layer->setDevice(app_state.device)
    app_state.layer->setPixelFormat(.BGRA8Unorm_sRGB)
    app_state.layer->setFramebufferOnly(true)
    app_state.layer->setFrame(wnd->frame())
    wnd->contentView()->setLayer(app_state.layer)
    wnd->setOpaque(true)

    {
        ds_desc := MTL.DepthStencilDescriptor.alloc()->init()
        defer ds_desc->release()

        ds_desc->setDepthCompareFunction(.Less)
        ds_desc->setDepthWriteEnabled(true)

        app_state.depth_state = app_state.device->newDepthStencilState(ds_desc)
    }

    // creating pso, architectually correct
    {
        lib, err := app_state.device->newLibraryWithFile(NS.AT("shader.metallib"))
        if err != nil {
            fmt.eprintln("Failed to load shader.metallib")
            return
        }
        defer lib->release()

        vfn := lib->newFunctionWithName(NS.AT("vertex_main"))
        ffn := lib->newFunctionWithName(NS.AT("fragment_main"))

        if vfn == nil {
            fmt.eprintln("vertex_main not found")
            return
        }

        if ffn == nil {
            fmt.eprintln("fragment_main not found")
            return
        }

        defer vfn->release()
        defer ffn->release()

        desc := MTL.RenderPipelineDescriptor.alloc()->init()
        defer desc->release()

        desc->setVertexFunction(vfn)
        desc->setFragmentFunction(ffn)
        desc->colorAttachments()->object(0)->setPixelFormat(.BGRA8Unorm_sRGB)
        desc->setDepthAttachmentPixelFormat(.Depth32Float)
        vdesc := MTL.VertexDescriptor.vertexDescriptor()
        // attribute(0) = position
        vdesc->attributes()->object(0)->setFormat(.Float3)
        vdesc->attributes()->object(0)->setOffset(0)
        vdesc->attributes()->object(0)->setBufferIndex(0)
        // attribute(1) = normal
        vdesc->attributes()->object(1)->setFormat(.Float3)
        vdesc->attributes()->object(1)->setOffset(12)
        vdesc->attributes()->object(1)->setBufferIndex(0)
        // Vertex stride:
        // float3 position = 12 bytes
        // float3 normal   = 12 bytes
        // total           = 24 bytes
        vdesc->layouts()->object(0)->setStride(24)
        vdesc->layouts()->object(0)->setStepFunction(.PerVertex)

        desc->setVertexDescriptor(vdesc)

        app_state.pso, err = app_state.device->newRenderPipelineStateWithDescriptor(desc)

        if err != nil {
            fmt.eprintf("PSO creation failed: %v\n", err)
            return
        }

        if app_state.pso == nil {
            fmt.eprintln("PSO is nil")
            return
        }
    }
    defer app_state.pso->release()

    // reading GLTF -- supposing architectually correct
    opts: cgltf.options
    data, parse_ok := cgltf.parse_file(opts, "ToyCar.glb")
    if parse_ok != .success { fmt.eprintln("Missing attachments/ToyCar.glb"); return }
    defer cgltf.free(data)

    if cgltf.load_buffers(opts, data, "attachments/ToyCar.glb") != .success {
        fmt.eprintln("Buffer load failed"); return
    }
    if len(data.scene.nodes) == 0 || data.scene.nodes[0].mesh == nil {
        fmt.eprintln("No mesh"); return
    }

    prim := data.scene.nodes[0].mesh.primitives[0]

    pos_acc, norm_acc: ^cgltf.accessor
    for &attr in prim.attributes {
        if attr.type == .position { pos_acc = attr.data }
        if attr.type == .normal   { norm_acc = attr.data }
    }
    if pos_acc == nil { fmt.eprintln("No positions"); return }

    app_state.num_verts = pos_acc.count
    verts := make([]Vertex, app_state.num_verts)
    defer delete(verts)

    for i in 0..<app_state.num_verts {
        _ = cgltf.accessor_read_float(pos_acc, uint(i), &verts[i].position[0], 3)
        if norm_acc != nil {
            _ = cgltf.accessor_read_float(norm_acc, uint(i), &verts[i].normal[0], 3)
        }
    }

    // creating metal buffers
    if prim.indices != nil {
        app_state.idx_count = u32(prim.indices.count)
        indices := make([]u32, app_state.idx_count)
        defer delete(indices)
        for i in 0..<app_state.idx_count {
            tmp: u32
            _ = cgltf.accessor_read_uint(prim.indices, uint(i), ([^]u32)(&tmp), 1)
            indices[i] = tmp
        }
        app_state.idx_buf = app_state.device->newBufferWithSlice(indices[:], {})
    }
    defer app_state.idx_buf->release()

    app_state.vert_buf = app_state.device->newBufferWithSlice(verts[:], {})
    defer app_state.vert_buf->release()

    fmt.printf("Loaded ToyCar: %d verts, %d indices\n", app_state.num_verts, app_state.idx_count)

    app_state.queue = app_state.device->newCommandQueue()
    defer app_state.queue->release()

    model := linalg.MATRIX4F32_IDENTITY
    camera_pos := [3]f32{-300, -300, -300}
    target := [3]f32{0, 0, 0}
    up := [3]f32{0, 0, -1}
    fov_rad := math.to_radians(f32(50.0))
    ratio : f32 = 1024.0/768.0
    min_view : f32 = 0.1
    max_view : f32 = 1000.0

    view  := linalg.matrix4_look_at_f32(camera_pos, target, up)
    proj  := linalg.matrix4_perspective_f32(fov_rad, ratio, min_view, max_view)
    mvp   := proj * view * model

    mvp_slice := []linalg.Matrix4f32{mvp}
    app_state.mvp_buf   = app_state.device->newBufferWithSlice(mvp_slice[:], {})
    defer app_state.mvp_buf->release()


    // creating display link
    disp_link := CA.MetalDisplayLink_alloc()
    if disp_link == nil {
        fmt.println("Failed to allocate CAMetalDisplayLink. Requires macOS 14.0+")
        return
    }


    disp_link->initWithMetalLayer(app_state.layer)
    disp_link->setPreferredFrameRateRange(CA.FrameRateRange{
        minimum   = 60.0,
        maximum   = 120.0,
        preferred = 120.0,
    });
    
    
    {
        class_name :: "OdinMetalDisplayLinkDelegate"
        class := NS.objc_allocateClassPair(
            intrinsics.objc_find_class("NSObject"),
            strings.clone_to_cstring("OdinMetalDisplayLinkDelegate"),
            0,
        )
        if class == nil {
            fmt.println("failed to create a display delegate")
            return
        }
        mdl_needs_update :: proc "c" (self: NS.id, _cmd: NS.SEL, link: ^CA.MetalDisplayLink, update: ^CA.MetalDisplayLinkUpdate) {
            context = runtime.default_context()
            drawable := update->drawable()

            if drawable == nil { return }

            pass := MTL.RenderPassDescriptor.renderPassDescriptor()

            col := pass->colorAttachments()->object(0)
            col->setTexture(drawable->texture())
            col->setLoadAction(.Clear)
            col->setClearColor(MTL.ClearColor{0.03, 0.05, 0.12, 1.0})
            col->setStoreAction(.Store)

            // Depth texture
            ddesc := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(.Depth32Float, 1024, 768, false)
            dtex  := app_state.device->newTextureWithDescriptor(ddesc)
            defer dtex->release()   // defer inside loop body: fires at end of this iteration — correct here
            datt  := pass->depthAttachment()
            datt->setTexture(dtex)
            datt->setLoadAction(.Clear)
            datt->setStoreAction(.DontCare)

            cmd := app_state.queue->commandBuffer()
            enc := cmd->renderCommandEncoderWithDescriptor(pass)

            enc->setDepthStencilState(app_state.depth_state)
            enc->setRenderPipelineState(app_state.pso)
            enc->setVertexBuffer(app_state.vert_buf, 0, 0)
            enc->setVertexBuffer(app_state.mvp_buf,  0, 1)

            if app_state.idx_buf != nil {
                enc->drawIndexedPrimitives(.Triangle, NS.UInteger(app_state.idx_count), .UInt32, app_state.idx_buf, 0)
            } else {
                enc->drawPrimitives(.Triangle, 0, NS.UInteger(app_state.num_verts))
            }

            enc->endEncoding()

            cmd->presentDrawable(drawable)
            cmd->commit()
        }
        NS.class_addMethod(class, intrinsics.objc_find_selector("metalDisplayLink:needsUpdate:"), auto_cast mdl_needs_update, "v@:@@")

        NS.objc_registerClassPair(class)
        del := NS.class_createInstance(class, 0)

        disp_link->setDelegate(del)
        disp_link->addToRunLoop(NS.RunLoop_mainRunLoop(), NS.RunLoopCommonModes)
    }

    app->run();
}
