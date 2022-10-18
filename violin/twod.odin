package violin

import "core:os"
import "core:fmt"
import "core:c/libc"
import "core:mem"
import "core:sync"
import "core:strings"

import vk "vendor:vulkan"
// import stb "vendor:stb/lib"
import stbi "vendor:stb/image"
import vma "../deps/odin-vma"

Rect :: struct {
  x: i32,
  y: i32,
  w: i32,
  h: i32,
}

Color :: struct {
  r: u8,
  g: u8,
  b: u8,
  a: u8,
}

init_twod_render_resources :: proc(using ctx: ^Context, render_pass_config: RenderPassConfigFlags) -> (twodh: TwoDRenderResourceHandle, err: Error) {
  // Create the resource
  twodh = auto_cast _create_resource(&resource_manager, .TwoDRenderResource) or_return
  twodr : ^TwoDRenderResource = auto_cast get_resource_any(&resource_manager, auto_cast twodh) or_return

  // Create the render pass
  twodr.render_pass = create_render_pass(ctx, render_pass_config) or_return
  
  // Create the render programs
  Vertex :: struct {
    pos: [2]f32,
  }
  
  vertices := [?]Vertex{
    {{-1.0, -1.0},},
    {{ 1.0, -1.0},},
    {{-1.0, 1.0},},
    {{ 1.0, 1.0},},
  }
  // Vertex :: struct {
  //   pos: [2]f32,
  // }
  
  // vertices := [?]Vertex{
  //   {{-1.0, -1.0}, {0.0, 0.0, 0.0}},
  //   {{ 1.0, -1.0}, {1.0, 0.0, 0.0}},
  //   {{ 1.0, 1.0}, {1.0, 1.0, 0.0}},
  //   {{-1.0, 1.0}, {0.0, 1.0, 1.0}},
  // }
  indices := [?]u16{
    0, 1, 2,
    2, 1, 3,
  }

  color_bindings := [?]vk.DescriptorSetLayoutBinding {
    vk.DescriptorSetLayoutBinding {
      binding = 1,
      descriptorType = .UNIFORM_BUFFER,
      stageFlags = { .VERTEX },
      descriptorCount = 1,
      pImmutableSamplers = nil,
    },
  }

  // bindings := [?]vk.DescriptorSetLayoutBinding {
  //   vk.DescriptorSetLayoutBinding {
  //     binding = 1,
  //     descriptorType = .COMBINED_IMAGE_SAMPLER,
  //     stageFlags = { .FRAGMENT },
  //     descriptorCount = 1,
  //     pImmutableSamplers = nil,
  //   },
  // }

  inputs := [?]InputAttribute {
    {
      format = .R32G32_SFLOAT,
      location = 0,
      offset = auto_cast offset_of(Vertex, pos),
    },
  }

  vert_shader_path, ae1 :=  strings.concatenate_safe({ctx.violin_package_relative_path, "violin/shaders/colored_rect.vert"},
    context.temp_allocator)
  if ae1 != .None {
    err = .AllocationFailed
    return
  }
  fmt.println("vert_shader_path:", vert_shader_path)
  // defer delete(vert_shader_path)
  frag_shader_path, ae2 :=  strings.concatenate_safe({ctx.violin_package_relative_path, "violin/shaders/colored_rect.frag"},
    context.temp_allocator)
  if ae2 != .None {
    err = .AllocationFailed
    return
  }
  // defer delete_string(frag_shader_path)

  colored_rect_rpci := RenderProgramCreateInfo {
    pipeline_config = PipelineCreateConfig {
      vertex_shader_filepath = vert_shader_path, // TODO
      fragment_shader_filepath = frag_shader_path,
      render_pass = twodr.render_pass,
    },
    vertex_size = size_of(Vertex),
    buffer_bindings = color_bindings[:],
    input_attributes = inputs[:],
  }
  twodr.colored_rect_render_program = create_render_program(ctx, &colored_rect_rpci) or_return
  
  twodr.colored_rect_uniform_buffer = create_uniform_buffer(ctx, auto_cast (size_of(f32) * 8), .Dynamic) or_return
  twodr.rect_vertex_buffer = create_vertex_buffer(ctx, auto_cast &vertices[0], size_of(Vertex), 4) or_return
  twodr.rect_index_buffer = create_index_buffer(ctx, auto_cast &indices[0], 6) or_return

  // parameter_data := [8]f32 {
  //   auto_cast 100 / cast(f32)ctx.swap_chain.extent.width,
  //   auto_cast 100 / cast(f32)ctx.swap_chain.extent.height,
  //   auto_cast 320 / cast(f32)ctx.swap_chain.extent.width,
  //   auto_cast 200 / cast(f32)ctx.swap_chain.extent.height,
  //   auto_cast 245 / 255.0,
  //   auto_cast 252 / 255.0,
  //   auto_cast 1 / 255.0,
  //   auto_cast 255 / 255.0,
  // }
  // write_to_buffer(ctx, twodr.colored_rect_uniform_buffer, auto_cast &parameter_data[0], auto_cast (size_of(f32) * 8)) or_return

  return
}

// Internal Function :: Use destroy_resource() instead
__release_twod_render_resource :: proc(using ctx: ^Context, tdr: ^TwoDRenderResource) {
  destroy_index_buffer(ctx, tdr.rect_index_buffer)
  destroy_vertex_buffer(ctx, tdr.rect_vertex_buffer)
  destroy_resource_any(ctx, tdr.colored_rect_uniform_buffer)

  destroy_render_program(ctx, &tdr.colored_rect_render_program)
  destroy_render_pass(ctx, tdr.render_pass)
}

begin_render_pass_2d :: proc(using rctx: ^RenderContext, twod_handle: TwoDRenderResourceHandle) -> Error {
  twodr: ^TwoDRenderResource = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast twod_handle) or_return

  // Delegate
  begin_render_pass(rctx, twodr.render_pass) or_return

  return .Success
}

draw_colored_rect :: proc(using rctx: ^RenderContext, twod_handle: TwoDRenderResourceHandle, rect: ^Rect, color: ^Color) -> Error {
  // Obtain the resources
  twodr: ^TwoDRenderResource = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast twod_handle) or_return
  vbuf: ^VertexBuffer = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast twodr.rect_vertex_buffer) or_return
  ibuf: ^IndexBuffer = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast twodr.rect_index_buffer) or_return
  ubuf: ^Buffer = auto_cast get_resource_any(&rctx.ctx.resource_manager, auto_cast twodr.colored_rect_uniform_buffer) or_return

  // Reference the render program
  rp := &twodr.colored_rect_render_program

  // Write the input to the uniform buffer
  parameter_data := [?]f32 {
    auto_cast rect.x / cast(f32)rctx.ctx.swap_chain.extent.width,
    auto_cast rect.y / cast(f32)rctx.ctx.swap_chain.extent.height,
    auto_cast rect.w / cast(f32)rctx.ctx.swap_chain.extent.width,
    auto_cast rect.h / cast(f32)rctx.ctx.swap_chain.extent.height,
    auto_cast color.r / 255.0,
    auto_cast color.g / 255.0,
    auto_cast color.b / 255.0,
    auto_cast color.a / 255.0,
  }
  write_to_buffer(ctx, twodr.colored_rect_uniform_buffer, auto_cast &parameter_data[0], auto_cast (size_of(f32) * 8)) or_return

  // Setup viewport and clip --- TODO this ain't true
  _set_viewport_cmd(command_buffer, 0, 0, auto_cast ctx.swap_chain.extent.width,
    auto_cast ctx.swap_chain.extent.height)
  _set_scissor_cmd(command_buffer, 0, 0, ctx.swap_chain.extent.width, ctx.swap_chain.extent.height)

  // Queue Buffer Write
  MAX_DESC_SET_WRITES :: 8
  writes: [MAX_DESC_SET_WRITES]vk.WriteDescriptorSet
  buffer_infos: [1]vk.DescriptorBufferInfo
  buffer_info_index := 0
  write_index := 0
  
  // Allocate the descriptor set from the pool
  descriptor_set_index := descriptor_sets_index

  set_alloc_info := vk.DescriptorSetAllocateInfo {
    sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
    // Use the descriptor pool we created earlier (the one dedicated to this frame)
    descriptorPool = descriptor_pool,
    descriptorSetCount = 1,
    pSetLayouts = &twodr.colored_rect_render_program.descriptor_layout,
  }
  vkres := vk.AllocateDescriptorSets(ctx.device, &set_alloc_info, &descriptor_sets[descriptor_set_index])
  if vkres != .SUCCESS {
    fmt.eprintln("vkAllocateDescriptorSets failed:", vkres)
    return .NotYetDetailed
  }

  desc_set := descriptor_sets[descriptor_set_index]
  descriptor_sets_index += set_alloc_info.descriptorSetCount

  // Describe the uniform buffer binding
  buffer_infos[0].buffer = ubuf.buffer
  buffer_infos[0].offset = 0
  buffer_infos[0].range = ubuf.size

  // Element Vertex Shader Uniform Buffer
  write := &writes[write_index]
  write_index += 1

  write.sType = .WRITE_DESCRIPTOR_SET
  write.dstSet = desc_set
  write.descriptorCount = 1
  write.descriptorType = .UNIFORM_BUFFER
  write.pBufferInfo = &buffer_infos[0]
  write.dstArrayElement = 0
  write.dstBinding = rp.layout_bindings[0].binding
  
  vk.UpdateDescriptorSets(ctx.device, auto_cast write_index, &writes[0], 0, nil)

  vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, rp.pipeline.layout, 0, 1, &desc_set, 0, nil)

  vk.CmdBindPipeline(command_buffer, .GRAPHICS, rp.pipeline.handle)

  vk.CmdBindIndexBuffer(command_buffer, ibuf.buffer, 0, ibuf.index_type) // TODO -- support other index types

  // const VkDeviceSize offsets[1] = {0};
  // vkCmdBindVertexBuffers(command_buffer, 0, 1, &cmd->render_program.data->vertices->buf, offsets);
  // // vkCmdDraw(command_buffer, 3 * 2 * 6, 1, 0, 0);
  // int index_draw_count = cmd->render_program.data->specific_index_draw_count;
  // if (!index_draw_count)
  //   index_draw_count = cmd->render_program.data->indices->capacity;
  offsets: vk.DeviceSize = 0
  vk.CmdBindVertexBuffers(command_buffer, 0, 1, &vbuf.buffer, &offsets)
  // TODO -- specific index draw count

  // // printf("index_draw_count=%i\n", index_draw_count);
  // // printf("cmd->render_program.data->indices->capacity=%i\n", cmd->render_program.data->indices->capacity);
  // // printf("cmd->render_program.data->specific_index_draw_count=%i\n",
  // //        cmd->render_program.data->specific_index_draw_count);

  // vkCmdDrawIndexed(command_buffer, index_draw_count, 1, 0, 0, 0);
  vk.CmdDrawIndexed(command_buffer, auto_cast ibuf.index_count, 1, 0, 0, 0) // TODO -- index_count as u32?
  // fmt.print("ibuf.index_count:", ibuf.index_count)

  return .Success
}