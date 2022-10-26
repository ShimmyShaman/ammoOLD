package launcher

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

import "vendor:sdl2"
import stbtt "vendor:stb/truetype"

import vi "../../violin"

main :: proc() {
  // TODO -- debug convenience delay
  time.sleep(time.Second * 1)

  // Initialize Renderer
  ctx, err := vi.init("../")
  defer vi.quit(ctx)
  if err != .Success {
    fmt.println("init problem:", err)
    return
  }

  launcher_data: LauncherData

  // Begin Network Connection
  // TODO begin_async
  thread := thread.create_and_start_with_data(&launcher_data.net, begin_client_network_connection)

  _begin_game_loop(ctx, &launcher_data)
  // time.sleep(time.Second * 10)

  retries := 4000
  launcher_data.net.should_close = true
  for launcher_data.net.status != .Shutdown {
    time.sleep(time.Millisecond * 10)
    retries -= 10
    if retries <= 0 {
      fmt.println("Network Thread is not closing, exiting anyway. TODO -- fix this")
      break
    }
  }
  // vi._resource_manager_report(&ctx.resource_manager)
}

_begin_game_loop :: proc(ctx: ^vi.Context, launcher_data: ^LauncherData) -> Error {
  rctx: ^vi.RenderContext
  verr: vi.Error

  // Temp Load Resources
  // RenderPasses
  rpass3d, rpass2d: vi.RenderPassResourceHandle
  err: vi.Error
  rpass3d, err = vi.create_render_pass(ctx, { .HasDepthBuffer })
  if err != .Success {
    fmt.println("create_render_pass 3 error")
    return .NotYetDetailed
  }
  defer vi.destroy_resource(ctx, rpass3d)

  // rpass2d, err = vi.create_render_pass(ctx, { })
  // if err != .Success {
  //   fmt.println("create_render_pass 2 error")
  //   return .NotYetDetailed
  // }
  // defer vi.destroy_resource(ctx, rpass2d)

  // Resources
  stamprr: vi.StampRenderResourceHandle
  stamprr, err = vi.init_stamp_batch_renderer(ctx, { .IsPresent }) // .HasPreviousColorPass,
  if err != .Success {
    fmt.println("init_stamp_batch_renderer error")
    return .NotYetDetailed
  }
  defer vi.destroy_resource(ctx, stamprr)

  parth: vi.TextureResourceHandle
  parth, err = vi.load_texture_from_file(ctx, "res/textures/parthenon.jpg")
  if err != .Success do return .NotYetDetailed
  defer vi.destroy_resource(ctx, parth)
 
  font: vi.FontResourceHandle
  font, err = vi.load_font(ctx, "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf", 25)
  defer vi.destroy_resource(ctx, font)
  if err != .Success do return .NotYetDetailed

  // rd2: vi.RenderData
  // rp2: vi.RenderProgram
  // rd2, rp2, err = load_textured_rect(ctx, rpass2d)
  // defer vi.destroy_render_program(ctx, &rp2)
  // defer vi.destroy_render_data(ctx, &rd2)
  // if err != .Success {
  //   fmt.println("load_textured_rect error")
  //   return .NotYetDetailed
  // }
  
  // rd3: vi.RenderData
  // rp3: vi.RenderProgram
  // rd3, rp3, err = load_cube(ctx, rpass3d)
  // defer vi.destroy_render_program(ctx, &rp3)
  // defer vi.destroy_render_data(ctx, &rd3)
  // if err != .Success {
  //   fmt.println("load_cube error")
  //   return .NotYetDetailed
  // }

  // Variables
  loop_start := time.now()
  prev := loop_start
  now: time.Time
  elapsed, prev_fps_check, total_elapsed: f32
  recent_frame_count := 0
  max_fps := 0
  min_fps := 10000000
  historical_frame_count := 0
  do_break_loop: bool

  // Loop
  fmt.println("Init Success. Entering Game Loop...")
  loop : for {
    // Handle Window Events
    do_break_loop = handle_window_events() or_return
    if do_break_loop {
      break loop
    }

    // fmt.println("framebuffers_3d", len(ctx.framebuffers_3d))
    // fmt.println("framebuffers_2d", len(ctx.swap_chain.present_framebuffers))
    // fmt.println("image_views", len(ctx.swap_chain.image_views))
    // fmt.println("images", len(ctx.swap_chain.images))

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

    // 3D
    // if vi.begin_render_pass(rctx, rpass3d) != .Success do break loop

    // // Create ViewProj Matrix
    // eye := la.vec3{6.0 * sdl2.cosf(total_elapsed), 5 + sdl2.cosf(total_elapsed * 0.6) * 3.0, 6.0 * sdl2.sinf(total_elapsed)}
    // // sqd: f32 = 8.0 / la.length_vec2(la.vec2{eyevent.x, eyevent.z})
    // // eyevent.x *= sqd
    // // eyevent.z *= sqd
    // // eye := la.vec3{-3.0, 0, 0}
    // view := la.mat4LookAt(eye, la.vec3{0, 0, 0}, la.vec3{0, -1, 0})
    // proj := la.mat4Perspective(0.7, cast(f32)ctx.swap_chain.extent.width / cast(f32)ctx.swap_chain.extent.height, 0.1, 100)
    // vp := proj * view
    // // vp := view * proj
    // vi.write_to_buffer(ctx, pvp, &vp, size_of(la.mat4))

    // if vi.draw_indexed(rctx, &rp3, &rd3) != .Success do return

    // // 2D
    // if vi.begin_render_pass(rctx, rpass2d) != .Success do break loop    

    // if vi.draw_indexed(rctx, &rp2, &rd2) != .Success do break loop

    if vi.stamp_begin(rctx, stamprr) != .Success do return .NotYetDetailed

    // sq := vi.Rect{100, 100, 300, 200}
    // co := vi.Color{220, 40, 185, 255}
    // if vi.stamp_colored_rect(rctx, stamprr, auto_cast &sq, auto_cast &co) != .Success do return .NotYetDetailed
    // sq = vi.Rect{200, 200, 100, 300}
    // co = vi.Color{255, 255, 15, 255}
    // if vi.stamp_colored_rect(rctx, stamprr, auto_cast &sq, auto_cast &co) != .Success do return .NotYetDetailed
    // sq = vi.Rect{280, 60, 420, 210}
    // co = vi.Color{15, 255, 255, 125}
    // if vi.stamp_textured_rect(rctx, stamprr, parth, auto_cast &sq, auto_cast &co) != .Success do return .NotYetDetailed

    // sq = vi.Rect{40, 272, 256, 256}
    // co = vi.Color{255, 255, 255, 255}
    // fontr: rawptr
    // fontr, verr = vi._get_resource(&ctx.resource_manager, auto_cast font)
    // if verr != .Success do return .NotYetDetailed
    // if vi.stamp_textured_rect(rctx, stamprr, (cast(^vi.Font)fontr).texture, auto_cast &sq, auto_cast &co) != .Success do return .NotYetDetailed
    // vi.stamp_text(rctx, stamprr, font, "Hello World", 300, 400, auto_cast &co)

    if vi.end_present(rctx) != .Success {
      fmt.println("end_present error")
      return .NotYetDetailed
    }
    recent_frame_count += 1

    // Auto-Leave
    // if recent_frame_count > 0 do break
    // for !handle_window_events(&muc) or_return {
    //   time.sleep(time.Millisecond)
    // }
    // break
  }

  avg_fps := cast(int) (cast(f64)(historical_frame_count + recent_frame_count) / time.duration_seconds(time.diff(loop_start, now)))
  fmt.println("FrameCount:", historical_frame_count + recent_frame_count, " ( max:", max_fps, "  min:",
  min_fps, " avg:", avg_fps, ")")

  return .Success
}

handle_window_events :: proc() -> (do_end_loop: bool, err: Error) {

  /* handle SDL events */
	event: sdl2.Event
  for sdl2.PollEvent(&event) {
		#partial switch event.type {
      case .QUIT:
        do_end_loop = true
        return
      case .MOUSEMOTION:
        ;
      case .MOUSEWHEEL:
        ;
      case .TEXTINPUT:
        ; // mu.input_text(muc, string(cstring(&event.text.text[0])))
      case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
        // button_map :: #force_inline proc(button: u8) -> (res: mu.Mouse, ok: bool) {
        //   ok = true;
        //   switch button {
        //     case 1: res = .LEFT;
        //     case 2: res = .MIDDLE;
        //     case 3: res = .RIGHT;
        //     case: ok = false;
        //   }
        //   return;
        // }
        // if btn, ok := button_map(event.button.button); ok {
        //   #partial switch event.type {
        //     case .MOUSEBUTTONDOWN:
        //       mu.input_mouse_down(muc, event.button.x, event.button.y, btn)
        //     case .MOUSEBUTTONUP:
        //       mu.input_mouse_up(muc, event.button.x, event.button.y, btn)
        //   }
        // }
        ;
      case .KEYDOWN, .KEYUP:
        if event.key.keysym.sym == .ESCAPE || event.key.keysym.sym == .F4 {
          do_end_loop = true
          return
        }
    }
  }

  return
}