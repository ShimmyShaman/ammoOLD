package launcher

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

import "vendor:sdl2"

import vi "../../violin"

main :: proc() {
  // TODO -- debug convenience delay
  time.sleep(time.Second * 1)

  // Initialize Renderer
  vctx, err := vi.init()
  defer vi.quit(&vctx)
  if err != .Success {
    fmt.println("init problem:", err)
    return
  }

  launcher_data: LauncherData

  // Begin Network Connection
  launcher_data.net.is_active = true
  thread := thread.create_and_start_with_data(&launcher_data.net, begin_client_network_connection)

  _begin_game_loop(&vctx, &launcher_data)

  launcher_data.net.should_close = true
  for launcher_data.net.is_active {
    time.sleep(time.Millisecond * 10)
  }
}

_begin_game_loop :: proc(ctx: ^vi.Context, launcher_data: ^LauncherData) -> Error {
  rctx: ^vi.RenderContext
  verr: vi.Error

  // Temp Load Resources
  // RenderPasses
  rpass3d, rpass2d, uipass: vi.RenderPassResourceHandle
  err: vi.Error
  rpass3d, err = vi.create_render_pass(ctx, { .HasDepthBuffer })
  if err != .Success {
    fmt.println("create_render_pass 3 error")
    return .NotYetDetailed
  }
  defer vi.destroy_resource(ctx, rpass3d)

  rpass2d, err = vi.create_render_pass(ctx, { .HasPreviousColorPass, .IsPresent })
  if err != .Success {
    fmt.println("create_render_pass 2 error")
    return .NotYetDetailed
  }
  defer vi.destroy_resource(ctx, rpass2d)

  // err = vi.init_ui_render_resources(ctx, { .IsPresent })
  // if err != .Success {
  //   fmt.println("create_render_pass 2 error")
  //   return
  // }
 
  // Resources
  rd2: vi.RenderData
  rp2: vi.RenderProgram
  rd2, rp2, err = load_textured_rect(ctx, rpass2d)
  defer vi.destroy_render_program(ctx, &rp2)
  defer vi.destroy_render_data(ctx, &rd2)
  if err != .Success {
    fmt.println("load_textured_rect error")
    return .NotYetDetailed
  }
  
  rd3: vi.RenderData
  rp3: vi.RenderProgram
  rd3, rp3, err = load_cube(ctx, rpass3d)
  defer vi.destroy_render_program(ctx, &rp3)
  defer vi.destroy_render_data(ctx, &rd3)
  if err != .Success {
    fmt.println("load_cube error")
    return .NotYetDetailed
  }

  // Variables
  loop_start := time.now()
  prev := loop_start
  now: time.Time
  elapsed, prev_fps_check, total_elapsed: f32
  recent_frame_count := 0
  max_fps := 0
  min_fps := 10000000
  historical_frame_count := 0

  // Loop
  fmt.println("Init Success. Entering Game Loop...")
  loop : for {
    window_event : sdl2.Event
    
    for sdl2.PollEvent(&window_event) {
      if window_event.type == .QUIT {
        break loop
      }
      if window_event.type == .KEYDOWN {
        if window_event.key.keysym.sym == .ESCAPE || window_event.key.keysym.sym == .F4 {
          break loop
        }
      }
    }

    // fmt.println("framebuffers_3d", len(vctx.framebuffers_3d))
    // fmt.println("framebuffers_2d", len(vctx.swap_chain.present_framebuffers))
    // fmt.println("image_views", len(vctx.swap_chain.image_views))
    // fmt.println("images", len(vctx.swap_chain.images))

    // FPS
    now = time.now()
    elapsed = auto_cast time.duration_seconds(time.diff(prev, now))
    total_elapsed += elapsed
    prev = now

    if total_elapsed - prev_fps_check >= 1.0 {
      historical_frame_count += recent_frame_count
      max_fps = max(max_fps, recent_frame_count)
      min_fps = min(min_fps, recent_frame_count)
      defer recent_frame_count = 0

      @(static) mod := 0
      if mod += 1; mod % 10 == 3 {
        fmt.println("fps:", recent_frame_count)
        // break loop
      }
      
      prev_fps_check = total_elapsed
    }

    // --- ### Draw the Frame ### ---
    // post_processing = false // So there is no intemediary render target draw... Everything is straight to present
    rctx, verr = vi.begin_present(ctx)
    if verr != .Success do return .NotYetDetailed

    // // 3D
    if vi.begin_render_pass(rctx, rpass3d) != .Success do break loop

    // // Create ViewProj Matrix
    // eye := la.vec3{6.0 * sdl2.cosf(total_elapsed), 5 + sdl2.cosf(total_elapsed * 0.6) * 3.0, 6.0 * sdl2.sinf(total_elapsed)}
    // // sqd: f32 = 8.0 / la.length_vec2(la.vec2{eye.x, eye.z})
    // // eye.x *= sqd
    // // eye.z *= sqd
    // // eye := la.vec3{-3.0, 0, 0}
    // view := la.mat4LookAt(eye, la.vec3{0, 0, 0}, la.vec3{0, -1, 0})
    // proj := la.mat4Perspective(0.7, cast(f32)vctx.swap_chain.extent.width / cast(f32)vctx.swap_chain.extent.height, 0.1, 100)
    // vp := proj * view
    // // vp := view * proj
    // vi.write_to_buffer(ctx, pvp, &vp, size_of(la.mat4))

    // if vi.draw_indexed(rctx, &rp3, &rd3) != .Success do return

    // // 2D
    if vi.begin_render_pass(rctx, rpass2d) != .Success do break loop    

    if vi.draw_indexed(rctx, &rp2, &rd2) != .Success do break loop

    // // sq := mu.Rect {100, 100, 500, 240}
    // // co := mu.Color {95, 120, 220, 255}
    // // vi.draw_ui_rect(rctx, &sq, &co)

    if vi.end_present(rctx) != .Success do break loop
 
    recent_frame_count += 1

    // Auto-Leave
    //  if recent_frame_count > 2 do break
    if time.duration_seconds(time.diff(loop_start, now)) >= 1.5 {
      break loop
    }
  }

  avg_fps := cast(int) (cast(f64)(historical_frame_count + recent_frame_count) / time.duration_seconds(time.diff(loop_start, now)))
  fmt.println("FrameCount:", historical_frame_count + recent_frame_count, " ( max:", max_fps, "  min:",
  min_fps, " avg:", avg_fps, ")")

  return .Success
}