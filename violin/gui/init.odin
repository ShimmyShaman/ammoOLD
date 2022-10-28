package violin_gui

import "core:fmt"
import "core:mem"
import vi "../../violin"

ControlType :: enum {
  GUIRoot = 1,
  Label,
  Button,
  Textbox,
}

HorizontalAlignment :: enum {
  Left = 1,
  Centred,
  Right,
}

VerticalAlignment :: enum {
  Top = 1,
  Centred,
  Bottom,
}

Rectf :: struct {
  x, y, width, height: f32,
}

Extent :: struct {
  left, top, right, bottom: f32,
}

_ControlLayout :: struct {
  requires_layout_update: bool,

  focused_child: ^Control,

  // Layout Properties
  horizontal_alignment: HorizontalAlignment,
  vertical_alignment: VerticalAlignment,
  preferred_width, preferred_height: f32,
  min_width, min_height: f32,
  max_width, max_height: f32,
  padding: Extent,

  determined_width_extent, determined_height_extent: f32,

  z_layer_index: int,
}

_ControlInfo :: struct {
  ctype: ControlType,
  _layout: _ControlLayout,
  id: string,
  parent: ^_ParentControlInfo,
  visible: bool,

  bounds: Rectf,
}

_ParentControlInfo :: struct {
  using _ctrlnfo: _ControlInfo,
  children: [dynamic]^Control,
}

GUIRoot :: struct {
  using _pcnfo: _ParentControlInfo,
}

Label :: struct {
  using _ctrlnfo: _ControlInfo,

  text: string,
  font_color: vi.Color,
  background_color: vi.Color,
  clip_text_to_bounds: bool,
}

Button :: struct {
  using _ctrlnfo: _ControlInfo,
}

Textbox :: struct {
  using _ctrlnfo: _ControlInfo,
}

Control :: struct #raw_union {
  using _info: _ControlInfo,
  root: GUIRoot,
  label: Label,
  button: Button,
  textbox: Textbox,
}

create_gui_root :: proc(ctx: ^vi.Context) -> (gui_root: ^GUIRoot, err: vi.Error) {
  gui_root = new(GUIRoot)
  
  gui_root.ctype = .GUIRoot
  gui_root.id = "GUIRoot"
  gui_root.parent = nil
  gui_root.visible = true

  gui_root.bounds.x = 0.0
  gui_root.bounds.y = 0.0
  gui_root.bounds.width = auto_cast ctx.swap_chain.extent.width
  gui_root.bounds.height = auto_cast ctx.swap_chain.extent.height

  // append(ctx.resize_callbacks, resize_callback) // TODO
  
  return
}

@(private) _destroy_control :: proc(control: rawptr) {
  #partial switch (cast(^_ControlInfo)control).ctype {
    case .GUIRoot:
      gui_root: ^GUIRoot = auto_cast control
      for child in gui_root.children {
        _destroy_control(child)
      }
    case:
      fmt.println("Unsupported control type:", (cast(^_ControlInfo)control).ctype)
    case .Label:
      label: ^Label = auto_cast control
      mem.free(label)
    // case .Button:
    //   delete(control)
    // case .Textbox:
    //   delete(control)
  }
}

destroy_gui :: proc(gui_root: ^^GUIRoot) {
  _destroy_control(gui_root^)
  gui_root^ = nil
}

@(private)_get_gui_root :: proc(p_control: rawptr) -> (gui_root: ^GUIRoot) {
  cnfo: ^_ControlInfo = auto_cast p_control
  if cnfo.ctype == .GUIRoot {
    gui_root = auto_cast p_control
  } else {
    gui_root = _get_gui_root(cnfo.parent)
  }
  return
}

// @(private)_name_control :: proc(control: rawptr, name: string) {
//   cnfo: ^_ControlInfo = auto_cast control



//   cnfo.id = name
// }

create_label :: proc(parent: rawptr, name_id: string = "label") -> (label: ^Label, err: vi.Error) {
  // Obtain the gui root
  gui_root: ^GUIRoot = _get_gui_root(parent)
  
  // Create the label
  label = new(Label)

  // Set the control info
  label.ctype = .Label
  label.id = name_id
  // TODO parent check
  // _name_control(label, name_id) TODO -- proper name control
  label.parent = auto_cast parent
  append(&(cast(^_ParentControlInfo)parent).children, auto_cast label)
  label.visible = true
  label.bounds = Rectf{0.0, 0.0, 80.0, 20.0}
  // label.bounds.left = 0.0
  // label.bounds.top = 0.0
  // label.bounds.right = 80.0
  // label.bounds.bottom = 20.0

  // Set the label info
  label.text = "Label"
  label.font_color = vi.Color{1.0, 1.0, 1.0, 1.0}
  label.background_color = vi.Color{0.0, 0.0, 0.0, 0.0}
  label.clip_text_to_bounds = false

  return
}

// create_button :: proc(parent: rawptr, name_id: string) -> (button: ^Button, err: vi.Error) {
//   return
// }

// create_textbox :: proc(parent: rawptr, name_id: string) -> (textbox: ^Textbox, err: vi.Error) {
//   return
// }