package client

import la "core:math/linalg/glsl"

import vk "vendor:vulkan"

import vi "../../violin"
 
 
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
//   // vi.create_graphics_pipeline(ctx, "cli/res/shaders/shader.vert", "cli/res/shaders/shader.frag", &VERTEX_BINDING, VERTEX_ATTRIBUTES[:]) or_return

//   // fmt.println("create_vertex_buffer")
//   // vi.create_vertex_buffer(ctx, raw_data(vertices[:]), size_of(Vertex), 4) or_return

//   // vi.create_index_buffer(ctx, &indices[0], len(indices)) or_return

//   return .Success
// }

load_textured_rect :: proc(ctx: ^vi.Context, render_pass: vi.RenderPassResourceHandle) -> (rd: vi.RenderData,
    rp: vi.RenderProgram, err: vi.Error) {
  
    Vertex :: struct
    {
      pos: [2]f32,
      uv: [2]f32,
    }
    
    vertices := [?]Vertex{
      {{-0.85, -0.85}, {0.0, 0.0}},
      {{-0.45, -0.85}, {1.0, 0.0}},
      {{-0.45, -0.45}, {1.0, 1.0}},
      {{-0.85, -0.45}, {0.0, 1.0}},
    }
    
    indices := [?]u16{
      0, 1, 2,
      2, 3, 0,
    }
  
    bindings := [?]vk.DescriptorSetLayoutBinding {
      vk.DescriptorSetLayoutBinding {
        binding = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        stageFlags = { .FRAGMENT },
        descriptorCount = 1,
        pImmutableSamplers = nil,
      },
    }
  
    inputs := [2]vi.InputAttribute {
      {
        format = .R32G32_SFLOAT,
        location = 0,
        offset = auto_cast offset_of(Vertex, pos),
      },
      {
        format = .R32G32_SFLOAT,
        location = 1,
        offset = auto_cast offset_of(Vertex, uv),
      },
    }
  
    rp_create_info := vi.RenderProgramCreateInfo {
      pipeline_config = vi.PipelineCreateConfig {
        vertex_shader_filepath = "cli/res/shaders/tex2d.vert",
        fragment_shader_filepath = "cli/res/shaders/tex2d.frag",
        render_pass = render_pass,
      },
      vertex_size = size_of(Vertex),
      buffer_bindings = bindings[:],
      input_attributes = inputs[:],
    }
  
    rp = vi.create_render_program(ctx, &rp_create_info) or_return
    // fmt.println("TODO dispose of render call specific resources & texture")
  
    // vertices = auto_cast &vertices[0],
    // vertex_count = 4,
    // indices = auto_cast &indices[0],
    // index_count = 6,
    // fmt.println("create_vertex_buffer")
    vi.create_vertex_buffer(ctx, &rd, auto_cast &vertices[0], size_of(Vertex), 4) or_return
  
    // fmt.println("create_index_buffer")
    vi.create_index_buffer(ctx, &rd, auto_cast &indices[0], 6) or_return
  
    texture := vi.load_texture_from_file(ctx, "cli/res/textures/parthenon.jpg") or_return
    // texture := vi.load_texture_from_file(ctx, "cli/res/textures/cube_texture.png") or_return
    append_elem(&rd.input, texture)
  
    return
  }
  
  load_cube :: proc(ctx: ^vi.Context, render_pass: vi.RenderPassResourceHandle) -> (rd: vi.RenderData,
    rp: vi.RenderProgram, err: vi.Error) {
  
    Vertex :: struct
    {
      pos: [3]f32,
      uv: [2]f32,
    }
    
    OTH : f32 : 1.0 / 3.0
    OTH2 : f32 : 2.0 / 3.0
  
    cube_vertex_data := [?]f32{
        // Left
        -1.0, -1.0, -1.0, 0.0, OTH,
        -1.0, -1.0, 1.0, 0.0, OTH2,
        -1.0, 1.0, -1.0, 0.25, OTH,
        -1.0, 1.0, 1.0, 0.25, OTH2,
        // Right
        1.0, -1.0, -1.0, 0.75, OTH,
        1.0, 1.0, -1.0, 0.5, OTH,
        1.0, -1.0, 1.0, 0.75, OTH2,
        1.0, 1.0, 1.0, 0.5, OTH2,
        // Back
        -1.0, -1.0, -1.0, 1.0, OTH,
        1.0, -1.0, -1.0, 0.75, OTH,
        -1.0, -1.0, 1.0, 1, OTH2,
        1.0, -1.0, 1.0, 0.75, OTH2,
        // Front
        -1.0, 1.0, -1.0, 0.25, OTH,
        -1.0, 1.0, 1.0, 0.25, OTH2,
        1.0, 1.0, -1.0, 0.5, OTH,
        1.0, 1.0, 1.0, 0.5, OTH2,
        // Top
        -1.0, -1.0, 1.0, 0.75, 1.0,
        1.0, -1.0, 1.0, 0.75, OTH2,
        -1.0, 1.0, 1.0, 0.5, 1.0,
        1.0, 1.0, 1.0, 0.5, OTH2,
        // Bottom
        -1.0, -1.0, -1.0, 0.75, 0.0,
        -1.0, 1.0, -1.0, 0.5, 0.0,
        1.0, -1.0, -1.0, 0.75, OTH,
        1.0, 1.0, -1.0, 0.5, OTH,
    }
  
    index_data := [?]u16 {
        0,  1,  2,  2,  1,  3,  4,  5,  6,  6,  5,  7,  8,  9,  10, 10, 9,  11,
        12, 13, 14, 14, 13, 15, 16, 17, 18, 18, 17, 19, 20, 21, 22, 22, 21, 23,
    }
  
    bindings := [?]vk.DescriptorSetLayoutBinding {
      vk.DescriptorSetLayoutBinding {
        binding = 0,
        descriptorType = .UNIFORM_BUFFER,
        stageFlags = { .VERTEX },
        descriptorCount = 1,
        pImmutableSamplers = nil,
      },
      vk.DescriptorSetLayoutBinding {
        binding = 1,
        descriptorType = .COMBINED_IMAGE_SAMPLER,
        stageFlags = { .FRAGMENT },
        descriptorCount = 1,
        pImmutableSamplers = nil,
      },
    }
  
    inputs := [2]vi.InputAttribute {
      {
        format = .R32G32B32_SFLOAT,
        location = 0,
        offset = auto_cast offset_of(Vertex, pos),
      },
      {
        format = .R32G32_SFLOAT,
        location = 1,
        offset = auto_cast offset_of(Vertex, uv),
      },
    }
  
    rp_create_info := vi.RenderProgramCreateInfo {
      pipeline_config = vi.PipelineCreateConfig {
        vertex_shader_filepath = "cli/res/shaders/tex3d.vert",
        fragment_shader_filepath = "cli/res/shaders/tex3d.frag",
        render_pass = render_pass,
      },
      vertex_size = size_of(Vertex),
      buffer_bindings = bindings[:],
      input_attributes = inputs[:],
    }
  
    // Create ViewProj Matrix
    view := la.mat4LookAt(la.vec3{0, 0, 3}, la.vec3{0, 0, 0}, la.vec3{0, 1, 0})
    proj := la.mat4Perspective(72, cast(f32)ctx.swap_chain.extent.width / cast(f32)ctx.swap_chain.extent.height, 0.1, 100)
    // vp := view * proj
    vp := proj * view
  
    // pvp := new_clone(vp)
    // // pvp := vi.allocate_input(ctx, type_of(la.mat4))
    // // vi.set_input_data(pvp, auto_cast vp)
    // append_elem(&rd.input, pvp)
  
    pvp := vi.create_uniform_buffer(ctx, size_of(la.mat4), .Dynamic) or_return
    vi.write_to_buffer(ctx, pvp, &vp, size_of(la.mat4))
    append_elem(&rd.input, pvp)
  
    rp = vi.create_render_program(ctx, &rp_create_info) or_return
  
    vi.create_vertex_buffer(ctx, &rd, auto_cast &cube_vertex_data[0], size_of(Vertex), len(cube_vertex_data) / 5) or_return
  
    vi.create_index_buffer(ctx, &rd, auto_cast &index_data[0], len(index_data)) or_return
  
    texture := vi.load_texture_from_file(ctx, "cli/res/textures/cube_texture.png") or_return
    append_elem(&rd.input, texture)
  
    return
  }