package violin

import "core:os"
import "core:fmt"
import "core:c/libc"
import "core:mem"
import "core:sync"

import vk "vendor:vulkan"
// import stb "vendor:stb/lib"
import stbi "vendor:stb/image"
import vma "../deps/odin-vma"

init_ui_render_resources :: proc(using ctx: ^Context, render_pass_config: RenderPassConfigFlags) -> (uih: UIRenderResourceHandle, err: Error) {
  // Create the resource
  uih = auto_cast _create_resource(&resource_manager, .UIRenderResource) or_return
  uir := get_resource_ui(&resource_manager, uih) or_return

  // Create the render pass
  uir.render_pass = create_render_pass(ctx, render_pass_config) or_return
  
  // Create the render programs
  Vertex :: struct {
    pos: [2]f32,
    color: [3]f32,
  }
  
  vertices := [?]Vertex{
    {{-1.0, -1.0}, {0.0, 0.0, 0.0}},
    {{ 1.0, -1.0}, {1.0, 0.0, 0.0}},
    {{ 1.0, 1.0}, {1.0, 1.0, 0.0}},
    {{-1.0, 1.0}, {0.0, 1.0, 1.0}},
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

  inputs := [2]InputAttribute {
    {
      format = .R32G32_SFLOAT,
      location = 0,
      offset = auto_cast offset_of(Vertex, pos),
    },
    {
      format = .R32G32_SFLOAT,
      location = 1,
      offset = auto_cast offset_of(Vertex, color),
    },
  }

  rp_create_info := RenderProgramCreateInfo {
    pipeline_config = PipelineCreateConfig {
      vertex_shader_filepath = "../violin/shaders/ui_color_rect.vert", // TODO
      fragment_shader_filepath = "../violin/shaders/ui_color_rect.frag",
      render_pass = uir.render_pass,
    },
    vertex_size = size_of(Vertex),
    buffer_bindings = bindings[:],
    input_attributes = inputs[:],
  }
  uir.colored_rect_render_program = create_render_program(ctx, &rp_create_info) or_return

  
  vi.create_vertex_buffer(ctx, &rd, auto_cast &vertices[0], size_of(Vertex), 4) or_return
  vi.create_index_buffer(ctx, &rd, auto_cast &indices[0], 6) or_return

  return
}

begin_ui_render_pass :: proc(using rctx: ^RenderContext, ui_handle: UIRenderResourceHandle) -> Error {
  uir: ^UIRenderResource = auto_cast get_resource(&rctx.vctx.resource_manager, ui_handle) or_return

  // Delegate
  begin_render_pass(rctx, uir.render_pass) or_return

  return .Success
}
  
Rect :: distinct mu.Rect
Color :: distinct mu.Color

draw_colored_rect :: proc(using rctx: ^RenderContext, ui_handle: UIRenderResourceHandle, rect: ^Rect, color: ^Color) -> Error {
  uir: ^UIRenderResource = auto_cast get_resource(&rctx.vctx.resource_manager, ui_handle) or_return

  return .Success
}