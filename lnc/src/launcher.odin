package launcher

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

import "vendor:sdl2"
import mu "vendor:microui"

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

  handle_2d: vi.StampRenderResourceHandle
  handle_2d, err = vi.init_stamp_batch_renderer(ctx, { .IsPresent }) // .HasPreviousColorPass,
  if err != .Success {
    fmt.println("create_render_pass 2D error")
    return .NotYetDetailed
  }
  defer vi.destroy_resource(ctx, handle_2d)
 
  // Resources
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

  muc: mu.Context
  mu.init(&muc)
  muc.text_width = get_text_width_for_font
  muc.text_height = get_text_height_for_font
  
  // Loop
  fmt.println("Init Success. Entering Game Loop...")
  loop : for {
    // Handle Window Events
    do_break_loop = handle_window_events(&muc) or_return
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

    // --- ### Handle User Input ### ---
    mu.begin(&muc)
    if mu.begin_window(&muc, "My Window", mu.Rect{10, 10, 300, 400}) {
      /* process ui herevent... */
      if mu.button(&muc, "My Button") != nil {
        fmt.printf("'My Button' was pressed\n")
      }

      mu.end_window(&muc)
    }
    mu.end(&muc)

    // --- ### Draw the Frame ### ---
    // post_processing = false // So there is no intemediary render target draw... Everything is straight to present
    rctx, verr = vi.begin_present(ctx)
    if verr != .Success {
      fmt.println("begin_present error")
      return .NotYetDetailed
    }

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

    if vi.stamp_begin(rctx, handle_2d) != .Success do return .NotYetDetailed

    sq := mu.Rect{100, 100, 300, 200}
    co := mu.Color{220, 40, 185, 255}
    vi.stamp_colored_rect(rctx, handle_2d, auto_cast &sq, auto_cast &co)
    sq = mu.Rect{200, 200, 100, 300}
    co = mu.Color{255, 255, 15, 255}
    vi.stamp_colored_rect(rctx, handle_2d, auto_cast &sq, auto_cast &co)
    // cmd : ^mu.Command
    // for mu.next_command(&muc, &cmd) {
    //   // fmt.println("next_command:", cmd)
    //   #partial switch v in cmd.variant {
    //     case ^mu.Command_Text:
    //       cmd_t : ^mu.Command_Text = auto_cast &cmd.variant
    //       fmt.println("text:", cmd_t)
    //     case ^mu.Command_Rect:
    //       cmd_r : ^mu.Command_Rect = auto_cast &cmd.variant
    //       fmt.println("rect:", cmd_r)
    //       vi.stamp_colored_rect(rctx, handle_2d, auto_cast &cmd_r.rect, auto_cast &cmd_r.color)
    //     case:
    //       fmt.println("unknown command:", cmd.variant)
    //     // case ^mu.Command_Jump:
    //     //   fmt.println("jump:")
    //     // case ^mu.Command_Icon:
    //     //   fmt.println("icon:")
    //     // case ^mu.Command_Clip:
    //     //   fmt.println("clip:")
    //   }
    // }

    // if vi.stamp_end(rctx, handle_2d) != .Success do return .NotYetDetailed

    if vi.end_present(rctx) != .Success {
      fmt.println("end_present error")
      return .NotYetDetailed
    }
    recent_frame_count += 1

    // Auto-Leave
    //  if recent_frame_count > 0 do break
    // if time.duration_seconds(time.diff(loop_start, now)) >= 1.5 {
    //   break loop
    // }
  }

  avg_fps := cast(int) (cast(f64)(historical_frame_count + recent_frame_count) / time.duration_seconds(time.diff(loop_start, now)))
  fmt.println("FrameCount:", historical_frame_count + recent_frame_count, " ( max:", max_fps, "  min:",
  min_fps, " avg:", avg_fps, ")")

  return .Success
}

handle_window_events :: proc(muc: ^mu.Context) -> (do_end_loop: bool, err: Error) {

  /* handle SDL events */
	event: sdl2.Event
  for sdl2.PollEvent(&event) {
		#partial switch event.type {
      case .QUIT:
        do_end_loop = false
        return
      case .MOUSEMOTION:
        mu.input_mouse_move(muc, event.motion.x, event.motion.y)
      case .MOUSEWHEEL:
        mu.input_scroll(muc, 0, event.wheel.y * -30)
      case .TEXTINPUT:
        mu.input_text(muc, string(cstring(&event.text.text[0])))
      case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
        button_map :: #force_inline proc(button: u8) -> (res: mu.Mouse, ok: bool) {
          ok = true;
          switch button {
            case 1: res = .LEFT;
            case 2: res = .MIDDLE;
            case 3: res = .RIGHT;
            case: ok = false;
          }
          return;
        }
        if btn, ok := button_map(event.button.button); ok {
          #partial switch event.type {
            case .MOUSEBUTTONDOWN:
              mu.input_mouse_down(muc, event.button.x, event.button.y, btn)
            case .MOUSEBUTTONUP:
              mu.input_mouse_up(muc, event.button.x, event.button.y, btn)
          }
        }
      case .KEYDOWN, .KEYUP:
        if event.key.keysym.sym == .ESCAPE || event.key.keysym.sym == .F4 {
          do_end_loop = true
          return
        }

        key_map :: #force_inline proc(x: sdl2.Keycode) -> (res: mu.Key, ok: bool) {
          ok = true
          #partial switch x {
            case .LSHIFT, .RSHIFT:
              res = .SHIFT
            case .LCTRL, .RCTRL:
              res = .CTRL
            case .LALT, .RALT:
              res = .ALT
            case .RETURN:
              res = .RETURN
            case .BACKSPACE:
              res = .BACKSPACE
            case:
              ok = false
          }
          return
        }
        if key, ok := key_map(auto_cast event.key.keysym.sym); ok {
          #partial switch event.type {
            case .KEYDOWN:
              mu.input_key_down(muc, key)
            case .KEYUP:
              mu.input_key_up(muc, key)
          }
        }
    }
  }

  return
}

get_text_width_for_font :: proc(font: mu.Font, text: string) -> i32 {
  return auto_cast len(text) * 4
}

get_text_height_for_font :: proc(font: mu.Font) -> i32 {
  return 18
}