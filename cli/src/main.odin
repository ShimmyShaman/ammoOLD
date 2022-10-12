package client

import "core:fmt"
import "core:time"
import "core:strings"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

import "vendor:sdl2"

import vi "violin"

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

  game_data: GameData

  // Begin Network Connection
  game_data.net_data.is_active = true
  thread := thread.create_and_start_with_data(&game.net_data, begin_client_network_connection)

  _begin_game_loop(&vctx, &game_data)

  net_data.should_close = true
  for net_data.is_active {
    time.sleep(time.Millisecond * 10)
  }
}

_begin_game_loop :: proc(ctx: ^vi.Context, game_data: ^GameData) -> Error {
  rctx: ^vi.RenderContext
  verr: vi.Error

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
    // if vi.begin_render_pass(rctx, rpass3d) != .Success do return

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
    // vi.write_to_buffer(&vctx, pvp, &vp, size_of(la.mat4))

    // if vi.draw_indexed(rctx, &rp3, &rd3) != .Success do return

    // // 2D
    // if vi.begin_render_pass(rctx, rpass2d) != .Success do return    

    // if vi.draw_indexed(rctx, &rp2, &rd2) != .Success do return

    // // sq := mu.Rect {100, 100, 500, 240}
    // // co := mu.Color {95, 120, 220, 255}
    // // vi.draw_ui_rect(rctx, &sq, &co)

    if vi.end_present(rctx) != .Success do return .NotYetDetailed
 
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

//   // RenderPasses
//   rpass3d, rpass2d, uipass: vi.RenderPassResourceHandle
//   rpass3d, err = vi.create_render_pass(&vctx, { .HasDepthBuffer })
//   if err != .Success {
//     fmt.println("create_render_pass 3 error")
//     return
//   }
//   defer vi.destroy_resource(&vctx, rpass3d)

//   rpass2d, err = vi.create_render_pass(&vctx, { .HasPreviousColorPass, .IsPresent })
//   if err != .Success {
//     fmt.println("create_render_pass 2 error")
//     return
//   }
//   defer vi.destroy_resource(&vctx, rpass2d)

//   // err = vi.init_ui_render_resources(&vctx, { .IsPresent })
//   // if err != .Success {
//   //   fmt.println("create_render_pass 2 error")
//   //   return
//   // }
 
//   // Resources
//   rd2: vi.RenderData
//   rp2: vi.RenderProgram
//   rd2, rp2, err = load_textured_rect(&vctx, rpass2d)
//   defer vi.destroy_render_program(&vctx, &rp2)
//   defer vi.destroy_render_data(&vctx, &rd2)
//   if err != .Success {
//     fmt.println("load_textured_rect error")
//     return
//   }
  
//   rd3: vi.RenderData
//   rp3: vi.RenderProgram
//   rd3, rp3, err = load_cube(&vctx, rpass3d)
//   defer vi.destroy_render_program(&vctx, &rp3)
//   defer vi.destroy_render_data(&vctx, &rd3)
//   if err != .Success {
//     fmt.println("load_cube error")
//     return
//   }
 
 
// load_gradient_rect :: proc(ctx: ^vi.Context) -> (vi.Error) {
  
//   Vertex :: struct
//   {
//     pos: [2]f32,
//     color: [3]f32,
//   }
  
//   VERTEX_BINDING := vk.VertexInputBindingDescription {
//     binding = 0,
//     stride = size_of(Vertex),
//     inputRate = .VERTEX,
//   };
  
//   VERTEX_ATTRIBUTES := [?]vk.VertexInputAttributeDescription {
//     {
//       binding = 0,
//       location = 0,
//       format = .R32G32_SFLOAT,
//       offset = cast(u32)offset_of(Vertex, pos),
//     },
//     {
//       binding = 0,
//       location = 1,
//       format = .R32G32B32_SFLOAT,
//       offset = cast(u32)offset_of(Vertex, color),
//     },
//   };
 
//   vertices := [?]Vertex{
//     {{-0.85, -0.85}, {0.0, 0.0, 1.0}},
//     {{ 0.85, -0.85}, {1.0, 0.0, 0.0}},
//     {{ 0.85,  0.85}, {0.0, 1.0, 0.0}},
//     {{-0.85,  0.85}, {1.0, 0.0, 0.0}},
//   }
  
//   indices := [?]u16{
//     0, 1, 2,
//     2, 3, 0,
//   }

//   // fmt.println("create_graphics_pipeline")
//   // vi.create_graphics_pipeline(ctx, "src/exp/shaders/shader.vert", "src/exp/shaders/shader.frag", &VERTEX_BINDING, VERTEX_ATTRIBUTES[:]) or_return

//   // fmt.println("create_vertex_buffer")
//   // vi.create_vertex_buffer(ctx, raw_data(vertices[:]), size_of(Vertex), 4) or_return

//   // vi.create_index_buffer(ctx, &indices[0], len(indices)) or_return

//   return .Success
// }

// load_textured_rect :: proc(ctx: ^vi.Context, render_pass: vi.RenderPassResourceHandle) -> (rd: vi.RenderData,
//   rp: vi.RenderProgram, err: vi.Error) {

//   Vertex :: struct
//   {
//     pos: [2]f32,
//     uv: [2]f32,
//   }
  
//   vertices := [?]Vertex{
//     {{-0.85, -0.85}, {0.0, 0.0}},
//     {{-0.45, -0.85}, {1.0, 0.0}},
//     {{-0.45, -0.45}, {1.0, 1.0}},
//     {{-0.85, -0.45}, {0.0, 1.0}},
//   }
  
//   indices := [?]u16{
//     0, 1, 2,
//     2, 3, 0,
//   }

//   bindings := [?]vk.DescriptorSetLayoutBinding {
//     vk.DescriptorSetLayoutBinding {
//       binding = 1,
//       descriptorType = .COMBINED_IMAGE_SAMPLER,
//       stageFlags = { .FRAGMENT },
//       descriptorCount = 1,
//       pImmutableSamplers = nil,
//     },
//   }

//   inputs := [2]vi.InputAttribute {
//     {
//       format = .R32G32_SFLOAT,
//       location = 0,
//       offset = auto_cast offset_of(Vertex, pos),
//     },
//     {
//       format = .R32G32_SFLOAT,
//       location = 1,
//       offset = auto_cast offset_of(Vertex, uv),
//     },
//   }

//   rp_create_info := vi.RenderProgramCreateInfo {
//     pipeline_config = vi.PipelineCreateConfig {
//       vertex_shader_filepath = "src/exp/shaders/tex2d.vert",
//       fragment_shader_filepath = "src/exp/shaders/tex2d.frag",
//       render_pass = render_pass,
//     },
//     vertex_size = size_of(Vertex),
//     buffer_bindings = bindings[:],
//     input_attributes = inputs[:],
//   }

//   rp = vi.create_render_program(ctx, &rp_create_info) or_return
//   // fmt.println("TODO dispose of render call specific resources & texture")

//   // vertices = auto_cast &vertices[0],
//   // vertex_count = 4,
//   // indices = auto_cast &indices[0],
//   // index_count = 6,
//   // fmt.println("create_vertex_buffer")
//   vi.create_vertex_buffer(ctx, &rd, auto_cast &vertices[0], size_of(Vertex), 4) or_return

//   // fmt.println("create_index_buffer")
//   vi.create_index_buffer(ctx, &rd, auto_cast &indices[0], 6) or_return

//   texture := vi.load_texture_from_file(ctx, "src/exp/textures/parthenon.jpg") or_return
//   // texture := vi.load_texture_from_file(ctx, "src/exp/textures/cube_texture.png") or_return
//   append_elem(&rd.input, texture)

//   return
// }

// load_cube :: proc(ctx: ^vi.Context, render_pass: vi.RenderPassResourceHandle) -> (rd: vi.RenderData,
//   rp: vi.RenderProgram, err: vi.Error) {

//   Vertex :: struct
//   {
//     pos: [3]f32,
//     uv: [2]f32,
//   }
  
//   OTH : f32 : 1.0 / 3.0
//   OTH2 : f32 : 2.0 / 3.0

//   cube_vertex_data := [?]f32{
//       // Left
//       -1.0, -1.0, -1.0, 0.0, OTH,
//       -1.0, -1.0, 1.0, 0.0, OTH2,
//       -1.0, 1.0, -1.0, 0.25, OTH,
//       -1.0, 1.0, 1.0, 0.25, OTH2,
//       // Right
//       1.0, -1.0, -1.0, 0.75, OTH,
//       1.0, 1.0, -1.0, 0.5, OTH,
//       1.0, -1.0, 1.0, 0.75, OTH2,
//       1.0, 1.0, 1.0, 0.5, OTH2,
//       // Back
//       -1.0, -1.0, -1.0, 1.0, OTH,
//       1.0, -1.0, -1.0, 0.75, OTH,
//       -1.0, -1.0, 1.0, 1, OTH2,
//       1.0, -1.0, 1.0, 0.75, OTH2,
//       // Front
//       -1.0, 1.0, -1.0, 0.25, OTH,
//       -1.0, 1.0, 1.0, 0.25, OTH2,
//       1.0, 1.0, -1.0, 0.5, OTH,
//       1.0, 1.0, 1.0, 0.5, OTH2,
//       // Top
//       -1.0, -1.0, 1.0, 0.75, 1.0,
//       1.0, -1.0, 1.0, 0.75, OTH2,
//       -1.0, 1.0, 1.0, 0.5, 1.0,
//       1.0, 1.0, 1.0, 0.5, OTH2,
//       // Bottom
//       -1.0, -1.0, -1.0, 0.75, 0.0,
//       -1.0, 1.0, -1.0, 0.5, 0.0,
//       1.0, -1.0, -1.0, 0.75, OTH,
//       1.0, 1.0, -1.0, 0.5, OTH,
//   }

//   index_data := [?]u16 {
//       0,  1,  2,  2,  1,  3,  4,  5,  6,  6,  5,  7,  8,  9,  10, 10, 9,  11,
//       12, 13, 14, 14, 13, 15, 16, 17, 18, 18, 17, 19, 20, 21, 22, 22, 21, 23,
//   }

//   bindings := [?]vk.DescriptorSetLayoutBinding {
//     vk.DescriptorSetLayoutBinding {
//       binding = 0,
//       descriptorType = .UNIFORM_BUFFER,
//       stageFlags = { .VERTEX },
//       descriptorCount = 1,
//       pImmutableSamplers = nil,
//     },
//     vk.DescriptorSetLayoutBinding {
//       binding = 1,
//       descriptorType = .COMBINED_IMAGE_SAMPLER,
//       stageFlags = { .FRAGMENT },
//       descriptorCount = 1,
//       pImmutableSamplers = nil,
//     },
//   }

//   inputs := [2]vi.InputAttribute {
//     {
//       format = .R32G32B32_SFLOAT,
//       location = 0,
//       offset = auto_cast offset_of(Vertex, pos),
//     },
//     {
//       format = .R32G32_SFLOAT,
//       location = 1,
//       offset = auto_cast offset_of(Vertex, uv),
//     },
//   }

//   rp_create_info := vi.RenderProgramCreateInfo {
//     pipeline_config = vi.PipelineCreateConfig {
//       vertex_shader_filepath = "src/exp/shaders/tex3d.vert",
//       fragment_shader_filepath = "src/exp/shaders/tex3d.frag",
//       render_pass = render_pass,
//     },
//     vertex_size = size_of(Vertex),
//     buffer_bindings = bindings[:],
//     input_attributes = inputs[:],
//   }

//   // Create ViewProj Matrix
//   view := la.mat4LookAt(la.vec3{0, 0, 3}, la.vec3{0, 0, 0}, la.vec3{0, 1, 0})
//   proj := la.mat4Perspective(72, cast(f32)ctx.swap_chain.extent.width / cast(f32)ctx.swap_chain.extent.height, 0.1, 100)
//   // vp := view * proj
//   vp := proj * view

//   // pvp := new_clone(vp)
//   // // pvp := vi.allocate_input(ctx, type_of(la.mat4))
//   // // vi.set_input_data(pvp, auto_cast vp)
//   // append_elem(&rd.input, pvp)

//   pvp = vi.create_uniform_buffer(ctx, size_of(la.mat4), .Dynamic) or_return
//   vi.write_to_buffer(ctx, pvp, &vp, size_of(la.mat4))
//   append_elem(&rd.input, pvp)

//   rp = vi.create_render_program(ctx, &rp_create_info) or_return

//   vi.create_vertex_buffer(ctx, &rd, auto_cast &cube_vertex_data[0], size_of(Vertex), len(cube_vertex_data) / 5) or_return

//   vi.create_index_buffer(ctx, &rd, auto_cast &index_data[0], len(index_data)) or_return

//   texture := vi.load_texture_from_file(ctx, "src/exp/textures/cube_texture.png") or_return
//   append_elem(&rd.input, texture)

//   return
// }