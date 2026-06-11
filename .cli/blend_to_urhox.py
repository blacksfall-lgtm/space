#!/usr/bin/env python3
"""Export a Blender scene into UrhoX scene/resources.

Run with Blender, for example:
  blender scene.blend --background --python tools/blender/blend_to_urhox.py -- \
      --out-dir /workspace/assets/blender/MyScene --scene-id MyScene --resource-prefix blender/MyScene

The exporter is intentionally pure Python. It writes:
  Scene.xml
  Meshes/*.mdl
  Materials/*.xml
  Textures/* plus texture XML configs
  Metadata/export_manifest.json
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple
import xml.etree.ElementTree as ET

try:
    import bpy  # type: ignore
except ImportError:  # Allows py_compile outside Blender.
    bpy = None  # type: ignore

try:
    import mathutils  # type: ignore
except ImportError:
    mathutils = None  # type: ignore


# Urho3D/UrhoX GraphicsDefs.h values.
TYPE_INT = 0
TYPE_FLOAT = 1
TYPE_VECTOR2 = 2
TYPE_VECTOR3 = 3
TYPE_VECTOR4 = 4
TYPE_UBYTE4 = 5
TYPE_UBYTE4_NORM = 6

SEM_POSITION = 0
SEM_NORMAL = 1
SEM_BINORMAL = 2
SEM_TANGENT = 3
SEM_TEXCOORD = 4
SEM_COLOR = 5
SEM_BLENDWEIGHTS = 6
SEM_BLENDINDICES = 7
SEM_LIGHTMAPUV = 8
SEM_OBJECTINDEX = 9

TRIANGLE_LIST = 0

DEFAULT_MATERIAL_REF = "Editor/Materials/Engine/GridMaterial.material"
DEFAULT_PUNCTUAL_LIGHT_RANGE = 40.0


@dataclass
class Vertex:
    position: Tuple[float, float, float]
    normal: Tuple[float, float, float]
    color: Tuple[int, int, int, int]
    uv: Tuple[float, float]
    uv2: Tuple[float, float]
    tangent: Tuple[float, float, float, float]


@dataclass
class GeometryRange:
    material_index: int
    index_start: int
    index_count: int
    center: Tuple[float, float, float]


@dataclass
class MaterialInfo:
    name: str
    diffuse_color: Tuple[float, float, float, float] = (1.0, 1.0, 1.0, 1.0)
    emissive_color: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    metallic: float = 0.0
    roughness: float = 0.5
    alpha: float = 1.0
    diffuse_texture: Optional[str] = None
    normal_texture: Optional[str] = None
    emissive_texture: Optional[str] = None
    specular_texture: Optional[str] = None
    has_vertex_color: bool = False


@dataclass
class MaterialExport:
    material_key: str
    resource_ref: str
    file_path: Path
    info: MaterialInfo


@dataclass
class MeshExport:
    object_name: str
    model_ref: str
    file_path: Path
    material_refs: List[str]
    geometry_material_indices: List[int]
    vertex_count: int
    index_count: int
    geometry_count: int


class Reporter:
    def __init__(self, strict_shader: bool = False) -> None:
        self.strict_shader = strict_shader
        self.warnings: List[str] = []
        self.errors: List[str] = []

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        print(f"[urhox-export][warn] {message}", file=sys.stderr)

    def error(self, message: str) -> None:
        self.errors.append(message)
        print(f"[urhox-export][error] {message}", file=sys.stderr)

    def shader_issue(self, material_name: str, message: str) -> None:
        full = f"material '{material_name}': {message}"
        if self.strict_shader:
            self.error(full)
        else:
            self.warn(full)


class BinaryWriter:
    def __init__(self) -> None:
        self.data = bytearray()

    def write_file_id(self, file_id: str) -> None:
        raw = file_id.encode("ascii")[:4]
        self.data.extend(raw)
        if len(raw) < 4:
            self.data.extend(b" " * (4 - len(raw)))

    def u32(self, value: int) -> None:
        self.data.extend(struct.pack("<I", value))

    def f32(self, value: float) -> None:
        self.data.extend(struct.pack("<f", float(value)))

    def boolean(self, value: bool) -> None:
        self.data.extend(struct.pack("<?", bool(value)))

    def vec2(self, value: Tuple[float, float]) -> None:
        self.data.extend(struct.pack("<2f", float(value[0]), float(value[1])))

    def vec3(self, value: Tuple[float, float, float]) -> None:
        self.data.extend(struct.pack("<3f", float(value[0]), float(value[1]), float(value[2])))

    def vec4(self, value: Tuple[float, float, float, float]) -> None:
        self.data.extend(struct.pack("<4f", float(value[0]), float(value[1]), float(value[2]), float(value[3])))

    def bytes(self, value: bytes) -> None:
        self.data.extend(value)


class NameAllocator:
    def __init__(self) -> None:
        self.used: Dict[str, int] = {}

    def allocate(self, stem: str, suffix: str) -> str:
        base = sanitize_name(stem)
        key = f"{base}{suffix}"
        index = self.used.get(key, 0)
        self.used[key] = index + 1
        if index == 0:
            return key
        return f"{base}_{index}{suffix}"


def sanitize_name(name: str, fallback: str = "unnamed") -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", name.strip())
    cleaned = cleaned.strip("._")
    if not cleaned:
        cleaned = fallback
    return cleaned[:96]


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def color_to_ubyte4(color: Sequence[float]) -> Tuple[int, int, int, int]:
    r = int(round(clamp01(color[0]) * 255.0))
    g = int(round(clamp01(color[1]) * 255.0))
    b = int(round(clamp01(color[2]) * 255.0))
    a = int(round(clamp01(color[3] if len(color) > 3 else 1.0) * 255.0))
    return r, g, b, a


def fmt_float(value: float) -> str:
    value = float(value)
    if abs(value) < 1.0e-7:
        value = 0.0
    return f"{value:.7g}"


def fmt_vec(values: Sequence[float]) -> str:
    return " ".join(fmt_float(v) for v in values)


def resolve_light_range(light: Any, light_type: str) -> float:
    if light_type == "Directional":
        return 0.0
    # UrhoX punctual lights need a finite range even when Blender custom attenuation is disabled.
    try:
        cutoff_distance = float(getattr(light, "cutoff_distance", 0.0) or 0.0)
    except (TypeError, ValueError):
        cutoff_distance = 0.0
    if cutoff_distance > 0.0:
        return cutoff_distance
    return DEFAULT_PUNCTUAL_LIGHT_RANGE


def convert_vec3(value: Any) -> Tuple[float, float, float]:
    # Blender XYZ/Z-up -> UrhoX YZX/Y-up, as used by XPrefabConverterLib.
    return float(value[1]), float(value[2]), float(value[0])


def convert_quat(value: Any) -> Tuple[float, float, float, float]:
    quat = value.normalized()
    return float(quat.w), float(quat.y), float(quat.z), float(quat.x)


def convert_scale(value: Any) -> Tuple[float, float, float]:
    return float(value[1]), float(value[2]), float(value[0])


def matrix_to_urhox_transform(matrix: Any) -> Tuple[Tuple[float, float, float], Tuple[float, float, float, float], Tuple[float, float, float]]:
    loc, rot, scale = matrix.decompose()
    return convert_vec3(loc), convert_quat(rot), convert_scale(scale)


def element_desc(element_type: int, semantic: int, index: int = 0) -> int:
    return element_type | (semantic << 8) | (index << 16)


def indent_xml(elem: ET.Element, level: int = 0) -> None:
    pad = "\n" + level * "\t"
    child_pad = "\n" + (level + 1) * "\t"
    children = list(elem)
    if children:
        if not elem.text or not elem.text.strip():
            elem.text = child_pad
        for child in children:
            indent_xml(child, level + 1)
        if not children[-1].tail or not children[-1].tail.strip():
            children[-1].tail = pad
    if level and (not elem.tail or not elem.tail.strip()):
        elem.tail = pad


def write_xml(path: Path, root: ET.Element) -> None:
    indent_xml(root)
    tree = ET.ElementTree(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(path, encoding="utf-8", xml_declaration=True)


def add_attr(parent: ET.Element, name: str, value: Optional[str] = None) -> ET.Element:
    elem = ET.SubElement(parent, "attribute")
    elem.set("name", name)
    if value is not None:
        elem.set("value", value)
    return elem


def get_socket(node: Any, names: Sequence[str]) -> Optional[Any]:
    for name in names:
        if name in node.inputs:
            return node.inputs[name]
    return None


def socket_value(socket: Optional[Any], default: Any) -> Any:
    if socket is None:
        return default
    try:
        return socket.default_value
    except Exception:
        return default


class UrhoXExporter:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.out_dir = Path(args.out_dir).resolve()
        self.scene_id = sanitize_name(args.scene_id)
        self.resource_prefix = args.resource_prefix.strip("/") if args.resource_prefix else f"blender/{self.scene_id}"
        self.mesh_dir = self.out_dir / "Meshes"
        self.material_dir = self.out_dir / "Materials"
        self.texture_dir = self.out_dir / "Textures"
        self.metadata_dir = self.out_dir / "Metadata"
        self.reporter = Reporter(strict_shader=args.strict_shader)
        self.mesh_names = NameAllocator()
        self.material_names = NameAllocator()
        self.texture_names = NameAllocator()
        self.material_cache: Dict[str, MaterialExport] = {}
        self.texture_cache: Dict[Tuple[int, str], str] = {}
        self.mesh_exports: Dict[Any, MeshExport] = {}
        self.next_node_id = 2
        self.next_component_id = 3
        self.manifest_objects: List[Dict[str, Any]] = []
        self.manifest_resources: List[Dict[str, Any]] = []

    def run(self) -> int:
        if bpy is None:
            print("This script must be executed by Blender's Python interpreter.", file=sys.stderr)
            return 2

        if self.args.blend:
            bpy.ops.wm.open_mainfile(filepath=str(Path(self.args.blend).resolve()))

        self.prepare_dirs()
        self.warn_collection_instances()

        candidates = self.collect_candidate_objects()
        for obj in candidates:
            if obj.type == "MESH":
                mesh_export = self.export_mesh_object(obj)
                if mesh_export is not None:
                    self.mesh_exports[obj] = mesh_export

        final_objects = self.collect_final_objects(candidates)
        self.write_scene(final_objects)
        self.write_manifest(final_objects)

        if self.reporter.errors:
            return 1
        return 0

    def prepare_dirs(self) -> None:
        for directory in (self.out_dir, self.mesh_dir, self.material_dir, self.texture_dir, self.metadata_dir):
            directory.mkdir(parents=True, exist_ok=True)

    def resource_ref(self, path: Path) -> str:
        try:
            rel = path.resolve().relative_to(self.out_dir)
        except ValueError:
            rel = path.resolve().relative_to(path.resolve().anchor)
        rel_str = rel.as_posix()
        if self.resource_prefix:
            return f"{self.resource_prefix}/{rel_str}"
        return rel_str

    def collect_candidate_objects(self) -> List[Any]:
        scene_objects = list(bpy.context.scene.objects)
        if self.args.only_selected:
            selected = set(bpy.context.selected_objects)
            scene_objects = [obj for obj in scene_objects if obj in selected]

        candidates: List[Any] = []
        for obj in scene_objects:
            if not self.should_consider_object(obj):
                continue
            candidates.append(obj)
        return candidates

    def collect_final_objects(self, candidates: Sequence[Any]) -> List[Any]:
        final: List[Any] = []
        for obj in candidates:
            if obj.type == "MESH":
                if obj in self.mesh_exports:
                    final.append(obj)
            elif obj.type == "LIGHT":
                if not self.args.no_lights and self.light_supported(obj):
                    final.append(obj)
            elif obj.type == "CAMERA":
                if not self.args.no_cameras:
                    final.append(obj)
        return final

    def should_consider_object(self, obj: Any) -> bool:
        if obj.type == "EMPTY" and getattr(obj, "instance_type", None) == "COLLECTION" and getattr(obj, "instance_collection", None):
            return False
        if obj.type not in {"MESH", "LIGHT", "CAMERA"}:
            return False
        if self.args.skip_disabled and self.is_disabled(obj):
            return False
        if obj.type == "LIGHT" and not self.light_supported(obj):
            return False
        return True

    def is_disabled(self, obj: Any) -> bool:
        try:
            if obj.hide_get():
                return True
        except Exception:
            pass
        return bool(getattr(obj, "hide_viewport", False) or getattr(obj, "hide_render", False))

    def light_supported(self, obj: Any) -> bool:
        light_type = getattr(obj.data, "type", "")
        if light_type == "AREA":
            shape = getattr(obj.data, "shape", "SQUARE")
            if shape in ("DISK", "ELLIPSE"):
                self.reporter.warn(f"light '{obj.name}' is AREA/{shape}, approximated as RectLight")
            return True
        return light_type in {"SUN", "POINT", "SPOT"}

    def warn_collection_instances(self) -> None:
        for obj in bpy.context.scene.objects:
            if obj.type == "EMPTY" and getattr(obj, "instance_type", None) == "COLLECTION" and getattr(obj, "instance_collection", None):
                self.reporter.warn(f"collection instance '{obj.name}' is skipped; real collection instancing is not exported yet")

    def export_mesh_object(self, obj: Any) -> Optional[MeshExport]:
        depsgraph = bpy.context.evaluated_depsgraph_get()
        eval_obj = obj.evaluated_get(depsgraph)
        mesh = None
        try:
            mesh = eval_obj.to_mesh(preserve_all_data_layers=True, depsgraph=depsgraph)
            if mesh is None:
                self.reporter.warn(f"mesh object '{obj.name}' produced no evaluated mesh")
                return None
            if not mesh.polygons:
                self.reporter.warn(f"mesh object '{obj.name}' has no polygons and is skipped")
                return None

            if any(mod.type == "ARMATURE" for mod in obj.modifiers):
                self.reporter.warn(f"mesh object '{obj.name}' has an Armature modifier; exporting evaluated static mesh only")

            try:
                mesh.calc_loop_triangles()
            except Exception as exc:
                self.reporter.error(f"failed to triangulate mesh '{obj.name}': {exc}")
                return None

            active_uv = mesh.uv_layers.active if mesh.uv_layers else None
            has_uv = active_uv is not None
            has_tangent = False
            if has_uv:
                try:
                    mesh.calc_tangents(uvmap=active_uv.name)
                    has_tangent = True
                except Exception as exc:
                    self.reporter.warn(f"mesh '{obj.name}' tangent generation failed: {exc}")
                    has_tangent = False

            color_attr = self.active_color_attribute(mesh)
            has_vertex_color = color_attr is not None

            triangles_by_mat: Dict[int, List[Any]] = {}
            for tri in mesh.loop_triangles:
                triangles_by_mat.setdefault(int(tri.material_index), []).append(tri)

            if not triangles_by_mat:
                self.reporter.warn(f"mesh object '{obj.name}' has no triangles and is skipped")
                return None

            elements: List[Tuple[int, int, int]] = [
                (TYPE_VECTOR3, SEM_POSITION, 0),
                (TYPE_VECTOR3, SEM_NORMAL, 0),
                (TYPE_UBYTE4_NORM, SEM_COLOR, 0),
            ]
            if has_uv:
                elements.append((TYPE_VECTOR2, SEM_TEXCOORD, 0))
            if has_tangent:
                elements.append((TYPE_VECTOR4, SEM_TANGENT, 0))
            elements.append((TYPE_VECTOR2, SEM_LIGHTMAPUV, 0))

            vertices: List[Vertex] = []
            indices: List[int] = []
            geometries: List[GeometryRange] = []
            geometry_material_refs: List[str] = []
            geometry_material_indices: List[int] = []
            materials = list(mesh.materials)

            for material_index in sorted(triangles_by_mat):
                material = materials[material_index] if 0 <= material_index < len(materials) else None
                mat_export = self.export_material(material, has_vertex_color=has_vertex_color)
                geometry_material_refs.append(mat_export.resource_ref if mat_export else DEFAULT_MATERIAL_REF)
                geometry_material_indices.append(material_index)

                index_start = len(indices)
                group_positions: List[Tuple[float, float, float]] = []
                for tri in triangles_by_mat[material_index]:
                    for loop_index in tri.loops:
                        loop = mesh.loops[loop_index]
                        vertex = mesh.vertices[loop.vertex_index]
                        position = convert_vec3(vertex.co)
                        normal = convert_vec3(loop.normal)
                        uv = self.loop_uv(active_uv, loop_index) if has_uv else (0.0, 0.0)
                        uv2 = uv
                        tangent = (0.0, 0.0, 0.0, 1.0)
                        if has_tangent:
                            tangent_dir = convert_vec3(loop.tangent)
                            tangent = (tangent_dir[0], tangent_dir[1], tangent_dir[2], float(loop.bitangent_sign))
                        color = self.loop_color(mesh, color_attr, loop_index, loop.vertex_index)
                        vertices.append(Vertex(position, normal, color, uv, uv2, tangent))
                        indices.append(len(vertices) - 1)
                        group_positions.append(position)

                index_count = len(indices) - index_start
                geometries.append(GeometryRange(material_index, index_start, index_count, center_of(group_positions)))

            if not vertices or not indices:
                self.reporter.warn(f"mesh object '{obj.name}' exported no vertex data and is skipped")
                return None

            model_name = self.mesh_names.allocate(obj.name, ".mdl")
            model_path = self.mesh_dir / model_name
            write_mdl(model_path, vertices, indices, geometries, elements)
            model_ref = self.resource_ref(model_path)

            export = MeshExport(
                object_name=obj.name,
                model_ref=model_ref,
                file_path=model_path,
                material_refs=geometry_material_refs,
                geometry_material_indices=geometry_material_indices,
                vertex_count=len(vertices),
                index_count=len(indices),
                geometry_count=len(geometries),
            )
            self.manifest_resources.append({
                "type": "model",
                "object": obj.name,
                "path": model_path.relative_to(self.out_dir).as_posix(),
                "resource": model_ref,
                "vertices": len(vertices),
                "indices": len(indices),
                "geometries": len(geometries),
            })
            return export
        finally:
            if mesh is not None:
                try:
                    eval_obj.to_mesh_clear()
                except Exception:
                    pass

    def active_color_attribute(self, mesh: Any) -> Optional[Any]:
        attrs = getattr(mesh, "color_attributes", None)
        if attrs is not None and attrs.active is not None:
            active = attrs.active
            if getattr(active, "data_type", "") in {"BYTE_COLOR", "FLOAT_COLOR"}:
                return active
            try:
                if len(active.data) and hasattr(active.data[0], "color"):
                    return active
            except Exception:
                pass
        legacy = getattr(mesh, "vertex_colors", None)
        if legacy is not None and legacy.active is not None:
            return legacy.active
        return None

    def loop_uv(self, uv_layer: Any, loop_index: int) -> Tuple[float, float]:
        uv = uv_layer.data[loop_index].uv
        v = 1.0 - float(uv.y) if self.args.flip_v else float(uv.y)
        return float(uv.x), v

    def loop_color(self, mesh: Any, color_attr: Optional[Any], loop_index: int, vertex_index: int) -> Tuple[int, int, int, int]:
        if color_attr is None:
            return 255, 255, 255, 255
        try:
            index = loop_index if getattr(color_attr, "domain", "CORNER") == "CORNER" else vertex_index
            color = color_attr.data[index].color
            return color_to_ubyte4(color)
        except Exception as exc:
            self.reporter.warn(f"failed reading vertex color on mesh '{mesh.name}': {exc}")
            return 255, 255, 255, 255

    def export_material(self, material: Optional[Any], has_vertex_color: bool = False) -> Optional[MaterialExport]:
        key = "__default__" if material is None else str(material.as_pointer())
        cached = self.material_cache.get(key)
        if cached is not None:
            return cached

        info = self.extract_material(material, has_vertex_color=has_vertex_color)
        mat_name = self.material_names.allocate(info.name, ".xml")
        mat_path = self.material_dir / mat_name
        root = ET.Element("material")

        ET.SubElement(root, "technique", {
            "name": self.select_technique(info),
            "quality": "0",
            "loddistance": "0",
        })
        if info.diffuse_texture:
            ET.SubElement(root, "texture", {"unit": "diffuse", "name": info.diffuse_texture})
        if info.normal_texture:
            ET.SubElement(root, "texture", {"unit": "normal", "name": info.normal_texture})
        if info.specular_texture:
            ET.SubElement(root, "texture", {"unit": "specular", "name": info.specular_texture})
        if info.emissive_texture:
            ET.SubElement(root, "texture", {"unit": "emissive", "name": info.emissive_texture})

        ET.SubElement(root, "parameter", {
            "name": "MatDiffColor",
            "value": fmt_vec(info.diffuse_color),
        })
        ET.SubElement(root, "parameter", {"name": "Metallic", "value": fmt_float(info.metallic)})
        ET.SubElement(root, "parameter", {"name": "Roughness", "value": fmt_float(info.roughness)})
        if any(c > 0.0 for c in info.emissive_color):
            ET.SubElement(root, "parameter", {
                "name": "MatEmissiveColor",
                "value": fmt_vec(info.emissive_color),
            })

        write_xml(mat_path, root)
        mat_ref = self.resource_ref(mat_path)
        export = MaterialExport(key, mat_ref, mat_path, info)
        self.material_cache[key] = export
        self.manifest_resources.append({
            "type": "material",
            "source": material.name if material else None,
            "path": mat_path.relative_to(self.out_dir).as_posix(),
            "resource": mat_ref,
            "technique": self.select_technique(info),
        })
        return export

    def extract_material(self, material: Optional[Any], has_vertex_color: bool) -> MaterialInfo:
        if material is None:
            return MaterialInfo(name="Default", has_vertex_color=has_vertex_color)

        info = MaterialInfo(name=material.name or "Material", has_vertex_color=has_vertex_color)
        diffuse = tuple(float(v) for v in getattr(material, "diffuse_color", (1.0, 1.0, 1.0, 1.0)))
        if len(diffuse) >= 4:
            info.diffuse_color = diffuse[:4]
            info.alpha = diffuse[3]

        node_tree = getattr(material, "node_tree", None)
        if node_tree is None:
            return info

        output = self.find_material_output(node_tree)
        if output is None:
            self.reporter.shader_issue(material.name, "no material output node; using diffuse_color only")
            return info

        surface = get_socket(output, ["Surface"])
        principled = None
        if surface is not None and surface.is_linked:
            from_node = surface.links[0].from_node
            if from_node.type == "BSDF_PRINCIPLED":
                principled = from_node
            else:
                self.reporter.shader_issue(material.name, f"surface shader node '{from_node.type}' is unsupported; using diffuse_color only")
                return info
        else:
            principled = self.find_principled(node_tree)

        if principled is None:
            self.reporter.shader_issue(material.name, "no Principled BSDF node; using diffuse_color only")
            return info

        self.warn_unsupported_principled_links(material, principled)

        base_socket = get_socket(principled, ["Base Color"])
        if base_socket is not None:
            if base_socket.is_linked:
                image = self.trace_image_from_socket(base_socket, material.name, "base color")
                if image is not None:
                    info.diffuse_texture = self.export_texture(image, material.name, "D", srgb=True)
                    info.diffuse_color = (1.0, 1.0, 1.0, info.diffuse_color[3])
            else:
                value = socket_value(base_socket, info.diffuse_color)
                info.diffuse_color = tuple(float(v) for v in value[:4])

        alpha_socket = get_socket(principled, ["Alpha"])
        if alpha_socket is not None:
            if alpha_socket.is_linked:
                self.reporter.shader_issue(material.name, "linked alpha is unsupported; using scalar/default alpha")
            else:
                info.alpha = float(socket_value(alpha_socket, info.alpha))
                info.diffuse_color = (info.diffuse_color[0], info.diffuse_color[1], info.diffuse_color[2], info.alpha)
        if getattr(material, "blend_method", "OPAQUE") not in {"OPAQUE", ""}:
            info.alpha = min(info.alpha, info.diffuse_color[3])

        metallic_socket = get_socket(principled, ["Metallic"])
        if metallic_socket is not None:
            if metallic_socket.is_linked:
                self.reporter.shader_issue(material.name, "linked metallic map is unsupported in v1; using scalar/default metallic")
            else:
                info.metallic = float(socket_value(metallic_socket, info.metallic))

        roughness_socket = get_socket(principled, ["Roughness"])
        if roughness_socket is not None:
            if roughness_socket.is_linked:
                self.reporter.shader_issue(material.name, "linked roughness map is unsupported in v1; using scalar/default roughness")
            else:
                info.roughness = float(socket_value(roughness_socket, info.roughness))

        normal_socket = get_socket(principled, ["Normal"])
        if normal_socket is not None and normal_socket.is_linked:
            image = self.trace_image_from_socket(normal_socket, material.name, "normal")
            if image is not None:
                info.normal_texture = self.export_texture(image, material.name, "N", srgb=False)

        emission_socket = get_socket(principled, ["Emission Color", "Emission"])
        emission_strength_socket = get_socket(principled, ["Emission Strength"])
        emission_strength = float(socket_value(emission_strength_socket, 1.0))
        if emission_socket is not None:
            if emission_socket.is_linked:
                image = self.trace_image_from_socket(emission_socket, material.name, "emission")
                if image is not None:
                    info.emissive_texture = self.export_texture(image, material.name, "E", srgb=True)
            else:
                value = socket_value(emission_socket, (0.0, 0.0, 0.0, 1.0))
                info.emissive_color = tuple(float(value[i]) * emission_strength for i in range(3))

        return info

    def find_material_output(self, node_tree: Any) -> Optional[Any]:
        for node in node_tree.nodes:
            if node.type == "OUTPUT_MATERIAL" and getattr(node, "is_active_output", True):
                return node
        for node in node_tree.nodes:
            if node.type == "OUTPUT_MATERIAL":
                return node
        return None

    def find_principled(self, node_tree: Any) -> Optional[Any]:
        found = [node for node in node_tree.nodes if node.type == "BSDF_PRINCIPLED"]
        if len(found) > 1:
            self.reporter.warn("material has multiple Principled BSDF nodes; using the first reachable/default node")
        return found[0] if found else None

    def warn_unsupported_principled_links(self, material: Any, principled: Any) -> None:
        allowed = {"Base Color", "Normal", "Emission Color", "Emission"}
        for socket in principled.inputs:
            if not socket.is_linked:
                continue
            if socket.name in allowed:
                continue
            self.reporter.shader_issue(material.name, f"linked Principled input '{socket.name}' is unsupported in v1")

    def trace_image_from_socket(self, socket: Any, material_name: str, role: str) -> Optional[Any]:
        if socket is None or not socket.is_linked:
            return None
        from_node = socket.links[0].from_node
        if from_node.type == "TEX_IMAGE":
            image = getattr(from_node, "image", None)
            if image is None:
                self.reporter.shader_issue(material_name, f"{role} Image Texture node has no image")
            return image
        if role == "normal" and from_node.type == "NORMAL_MAP":
            color_socket = get_socket(from_node, ["Color"])
            return self.trace_image_from_socket(color_socket, material_name, role)
        self.reporter.shader_issue(material_name, f"{role} link through node '{from_node.type}' is unsupported in v1")
        return None

    def export_texture(self, image: Any, material_name: str, suffix: str, srgb: bool) -> Optional[str]:
        cache_key = (int(image.as_pointer()), suffix)
        cached = self.texture_cache.get(cache_key)
        if cached:
            return cached

        source_path = self.image_source_path(image)
        ext = Path(source_path).suffix if source_path else Path(getattr(image, "filepath", "")).suffix
        if not ext:
            ext = ".png"
        ext = ext.lower()
        if ext not in {".png", ".jpg", ".jpeg", ".tga", ".bmp", ".dds", ".ktx"}:
            ext = ".png"
        texture_name = self.texture_names.allocate(f"{material_name}_{suffix}", ext)
        dest_path = self.texture_dir / texture_name

        if not self.copy_or_save_image(image, source_path, dest_path):
            self.reporter.shader_issue(material_name, f"failed to export texture image '{getattr(image, 'name', '<unnamed>')}'")
            return None

        self.write_texture_config(dest_path, srgb=srgb)
        texture_ref = self.resource_ref(dest_path)
        self.texture_cache[cache_key] = texture_ref
        self.manifest_resources.append({
            "type": "texture",
            "source": getattr(image, "filepath", "") or getattr(image, "name", ""),
            "path": dest_path.relative_to(self.out_dir).as_posix(),
            "resource": texture_ref,
            "srgb": srgb,
        })
        return texture_ref

    def image_source_path(self, image: Any) -> Optional[str]:
        filepath = getattr(image, "filepath", "")
        if not filepath:
            return None
        abs_path = bpy.path.abspath(filepath)
        return abs_path if abs_path and os.path.exists(abs_path) else None

    def copy_or_save_image(self, image: Any, source_path: Optional[str], dest_path: Path) -> bool:
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        if source_path and os.path.exists(source_path):
            shutil.copy2(source_path, dest_path)
            return True

        # Packed/generated images must be materialized by Blender.
        try:
            old_filepath_raw = getattr(image, "filepath_raw", "")
            old_file_format = getattr(image, "file_format", "PNG")
            image.filepath_raw = str(dest_path)
            if dest_path.suffix.lower() == ".png":
                image.file_format = "PNG"
            image.save()
            image.filepath_raw = old_filepath_raw
            image.file_format = old_file_format
            return dest_path.exists()
        except Exception as exc:
            self.reporter.warn(f"could not save packed/generated image '{getattr(image, 'name', '<unnamed>')}': {exc}")
            return False

    def write_texture_config(self, image_path: Path, srgb: bool) -> None:
        root = ET.Element("texture")
        if srgb:
            ET.SubElement(root, "srgb", {"enable": "true"})
        ET.SubElement(root, "quality", {"low": "0"})
        for platform, fmt in (("windows", "BC7"), ("android", "ASTC_6X6"), ("ios", "ASTC_6X6"), ("web", "ASTC_6X6")):
            platform_elem = ET.SubElement(root, "platform", {"name": platform})
            ET.SubElement(platform_elem, "compress", {"format": fmt})
        write_xml(image_path.with_suffix(".xml"), root)

    def select_technique(self, info: MaterialInfo) -> str:
        has_normal = bool(info.normal_texture)
        has_emissive = bool(info.emissive_texture) or any(c > 0.0 for c in info.emissive_color)
        has_alpha = info.alpha < 0.99 or info.diffuse_color[3] < 0.99
        has_diffuse_map = bool(info.diffuse_texture)
        has_vertex_color = info.has_vertex_color

        if has_normal and has_emissive and has_alpha:
            return "Techniques/PBR/PBRDiffNormalEmissiveAlpha.xml"
        if has_normal and has_emissive:
            return "Techniques/PBR/PBRDiffNormalEmissive.xml"
        if has_normal and has_alpha:
            return "Techniques/PBR/PBRDiffNormalAlpha.xml"
        if has_normal:
            return "Techniques/PBR/PBRDiffNormal.xml"
        if has_alpha:
            return "Techniques/PBR/PBRDiffAlpha.xml"
        if not has_diffuse_map and has_vertex_color:
            return "Techniques/PBR/PBRDiffVCol.xml"
        return "Techniques/PBR/PBRDiff.xml"

    def write_scene(self, objects: Sequence[Any]) -> None:
        final_set = set(objects)
        children: Dict[Optional[Any], List[Any]] = {None: []}
        for obj in objects:
            parent = self.nearest_exported_parent(obj, final_set)
            children.setdefault(parent, []).append(obj)
            children.setdefault(obj, [])

        root = ET.Element("scene", {"id": "1"})
        add_attr(root, "Name", self.scene_id)
        add_attr(root, "Time Scale", "1")
        add_attr(root, "Smoothing Constant", "50")
        add_attr(root, "Snap Threshold", "5")
        add_attr(root, "Elapsed Time", "0")
        next_node_attr = add_attr(root, "Next Replicated Node ID", "0")
        next_comp_attr = add_attr(root, "Next Replicated Component ID", "0")
        add_attr(root, "Next Local Node ID", "16777216")
        add_attr(root, "Next Local Component ID", "16777216")
        add_attr(root, "Variables")
        add_attr(root, "Variable Names", "")
        ET.SubElement(root, "component", {"type": "Octree", "id": "1"})
        ET.SubElement(root, "component", {"type": "DebugRenderer", "id": "2"})
        self.append_default_zone(root)

        for obj in children.get(None, []):
            self.append_node_xml(root, obj, final_set, children)

        next_node_attr.set("value", str(self.next_node_id))
        next_comp_attr.set("value", str(self.next_component_id))
        scene_path = self.out_dir / "Scene.xml"
        write_xml(scene_path, root)
        self.manifest_resources.append({
            "type": "scene",
            "path": scene_path.relative_to(self.out_dir).as_posix(),
            "resource": self.resource_ref(scene_path),
        })

    def append_default_zone(self, root: ET.Element) -> None:
        node_id = self.next_node_id
        self.next_node_id += 1
        node_elem = ET.SubElement(root, "node", {"id": str(node_id)})
        add_attr(node_elem, "Is Enabled", "true")
        add_attr(node_elem, "Name", "Zone")
        add_attr(node_elem, "Tags")
        add_attr(node_elem, "Position", "0 0 0")
        add_attr(node_elem, "Rotation", "1 0 0 0")
        add_attr(node_elem, "Scale", "1 1 1")
        add_attr(node_elem, "Variables")

        comp_id = self.next_component_id
        self.next_component_id += 1
        comp = ET.SubElement(node_elem, "component", {"type": "Zone", "id": str(comp_id)})
        add_attr(comp, "Bounding Box Min", "-1000 -1000 -1000")
        add_attr(comp, "Bounding Box Max", "1000 1000 1000")
        add_attr(comp, "Ambient Color", "0.3 0.3 0.3 1")
        add_attr(comp, "Fog Color", "0.231373 0.392157 0.658824 1")
        add_attr(comp, "Depth Fog Start", "100")
        add_attr(comp, "Depth Fog End", "300")
        add_attr(comp, "Depth Fog AutoCompute", "false")
        add_attr(comp, "Env Spec Texture", "TextureCube;Cube/Day/DaySpecularHDR.dds")
        add_attr(comp, "Bloom Threshold", "1")
        add_attr(comp, "Bloom Weight", "0.25")

        self.manifest_objects.append({
            "name": "Zone",
            "type": "ZONE",
            "node_id": node_id,
            "parent": None,
            "collections": [],
        })

    def append_node_xml(self, parent_elem: ET.Element, obj: Any, final_set: set, children: Dict[Optional[Any], List[Any]]) -> None:
        node_id = self.next_node_id
        self.next_node_id += 1
        node_elem = ET.SubElement(parent_elem, "node", {"id": str(node_id)})

        local_matrix = self.local_matrix_for(obj, final_set)
        position, rotation, scale = matrix_to_urhox_transform(local_matrix)

        add_attr(node_elem, "Is Enabled", "true")
        add_attr(node_elem, "Name", obj.name)
        add_attr(node_elem, "Tags")
        add_attr(node_elem, "Position", fmt_vec(position))
        add_attr(node_elem, "Rotation", fmt_vec(rotation))
        add_attr(node_elem, "Scale", fmt_vec(scale))
        add_attr(node_elem, "Variables")

        if obj.type == "MESH":
            self.append_static_model(node_elem, obj)
        elif obj.type == "LIGHT":
            self.append_light(node_elem, obj)
        elif obj.type == "CAMERA":
            self.append_camera(node_elem, obj)

        self.manifest_objects.append({
            "name": obj.name,
            "type": obj.type,
            "node_id": node_id,
            "parent": self.nearest_exported_parent(obj, final_set).name if self.nearest_exported_parent(obj, final_set) else None,
            "collections": [coll.name for coll in getattr(obj, "users_collection", [])],
        })

        for child in children.get(obj, []):
            self.append_node_xml(node_elem, child, final_set, children)

    def append_static_model(self, node_elem: ET.Element, obj: Any) -> None:
        mesh_export = self.mesh_exports[obj]
        comp_id = self.next_component_id
        self.next_component_id += 1
        comp = ET.SubElement(node_elem, "component", {"type": "StaticModel", "id": str(comp_id)})
        add_attr(comp, "Model", f"Model;{mesh_export.model_ref}")
        materials_value = "Material"
        for material_ref in mesh_export.material_refs:
            materials_value += f";{material_ref}"
        add_attr(comp, "Material", materials_value)
        add_attr(comp, "Cast Shadows", "true")

    def append_light(self, node_elem: ET.Element, obj: Any) -> None:
        comp_id = self.next_component_id
        self.next_component_id += 1
        comp = ET.SubElement(node_elem, "component", {"type": "Light", "id": str(comp_id)})
        light = obj.data
        light_type = {"SUN": "Directional", "POINT": "Point", "SPOT": "Spot", "AREA": "Rect"}.get(light.type, "Point")
        add_attr(comp, "Light Type", light_type)
        color = tuple(float(c) for c in getattr(light, "color", (1.0, 1.0, 1.0)))
        add_attr(comp, "Color", fmt_vec((color[0], color[1], color[2], 1.0)))
        is_directional = light.type == "SUN"
        add_attr(comp, "Brightness Multiplier", fmt_float(float(getattr(light, "energy", 1.0)) if is_directional else float(getattr(light, "energy", 1.0)) / 10.0))
        add_attr(comp, "Range", fmt_float(resolve_light_range(light, light_type)))
        if light.type == "SPOT":
            add_attr(comp, "Spot FOV", fmt_float(math.degrees(float(getattr(light, "spot_size", math.radians(45.0))))))
        if light.type == "AREA":
            shape = getattr(light, "shape", "SQUARE")
            size_x = float(getattr(light, "size", 1.0))
            size_y = float(getattr(light, "size_y", size_x)) if shape in ("RECTANGLE", "ELLIPSE") else size_x
            add_attr(comp, "Source Width", fmt_float(max(size_x, 0.01)))
            add_attr(comp, "Source Height", fmt_float(max(size_y, 0.01)))
        add_attr(comp, "Cast Shadows", "true" if getattr(light, "use_shadow", True) else "false")

    def append_camera(self, node_elem: ET.Element, obj: Any) -> None:
        comp_id = self.next_component_id
        self.next_component_id += 1
        comp = ET.SubElement(node_elem, "component", {"type": "Camera", "id": str(comp_id)})
        camera = obj.data
        add_attr(comp, "Near Clip", fmt_float(float(getattr(camera, "clip_start", 0.1))))
        add_attr(comp, "Far Clip", fmt_float(float(getattr(camera, "clip_end", 1000.0))))
        add_attr(comp, "FOV", fmt_float(math.degrees(float(getattr(camera, "angle", math.radians(45.0))))))

    def nearest_exported_parent(self, obj: Any, final_set: set) -> Optional[Any]:
        parent = obj.parent
        while parent is not None:
            if parent in final_set:
                return parent
            parent = parent.parent
        return None

    def local_matrix_for(self, obj: Any, final_set: set) -> Any:
        parent = self.nearest_exported_parent(obj, final_set)
        if parent is not None:
            return parent.matrix_world.inverted() @ obj.matrix_world
        return obj.matrix_world.copy()

    def write_manifest(self, objects: Sequence[Any]) -> None:
        manifest = {
            "schema": "urhox.blender_export.v1",
            "scene_id": self.scene_id,
            "source_blend": bpy.data.filepath,
            "resource_prefix": self.resource_prefix,
            "axis_conversion": "Blender XYZ/Z-up -> UrhoX YZX/Y-up",
            "objects_exported": len(objects),
            "resources": self.manifest_resources,
            "objects": self.manifest_objects,
            "warnings": self.reporter.warnings,
            "errors": self.reporter.errors,
            "options": {
                "skip_disabled": self.args.skip_disabled,
                "only_selected": self.args.only_selected,
                "flip_v": self.args.flip_v,
                "strict_shader": self.args.strict_shader,
                "no_cameras": self.args.no_cameras,
                "no_lights": self.args.no_lights,
            },
        }
        path = self.metadata_dir / "export_manifest.json"
        path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")


def center_of(points: Sequence[Tuple[float, float, float]]) -> Tuple[float, float, float]:
    if not points:
        return 0.0, 0.0, 0.0
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    zs = [p[2] for p in points]
    return (min(xs) + max(xs)) * 0.5, (min(ys) + max(ys)) * 0.5, (min(zs) + max(zs)) * 0.5


def bounds_of(vertices: Sequence[Vertex]) -> Tuple[Tuple[float, float, float], Tuple[float, float, float]]:
    if not vertices:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)
    xs = [v.position[0] for v in vertices]
    ys = [v.position[1] for v in vertices]
    zs = [v.position[2] for v in vertices]
    return (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


def write_mdl(path: Path, vertices: Sequence[Vertex], indices: Sequence[int], geometries: Sequence[GeometryRange], elements: Sequence[Tuple[int, int, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    writer = BinaryWriter()
    writer.write_file_id("UMD2")

    writer.u32(1)  # vertex buffers
    writer.u32(len(vertices))
    writer.u32(len(elements))
    for element_type, semantic, index in elements:
        writer.u32(element_desc(element_type, semantic, index))
    writer.u32(0)  # morph range start
    writer.u32(0)  # morph range count
    for vertex in vertices:
        write_vertex(writer, vertex, elements)

    index_size = 2 if len(vertices) <= 0xFFFF else 4
    writer.u32(1)  # index buffers
    writer.u32(len(indices))
    writer.u32(index_size)
    if index_size == 2:
        for index in indices:
            writer.bytes(struct.pack("<H", index))
    else:
        for index in indices:
            writer.bytes(struct.pack("<I", index))

    writer.u32(len(geometries))
    for geometry in geometries:
        writer.u32(0)  # bone mapping count
        writer.u32(1)  # LOD levels
        writer.f32(0.0)
        writer.u32(TRIANGLE_LIST)
        writer.u32(0)  # vertex buffer ref
        writer.u32(0)  # index buffer ref
        writer.u32(geometry.index_start)
        writer.u32(geometry.index_count)

    writer.u32(0)  # morph count
    writer.u32(0)  # skeleton bone count
    min_bound, max_bound = bounds_of(vertices)
    writer.vec3(min_bound)
    writer.vec3(max_bound)
    for geometry in geometries:
        writer.vec3(geometry.center)

    writer.boolean(False)  # generate second UV
    writer.u32(0)          # second UV sizes
    writer.boolean(False)  # has stroke normal
    writer.u32(0)          # convex collision count

    path.write_bytes(writer.data)


def write_vertex(writer: BinaryWriter, vertex: Vertex, elements: Sequence[Tuple[int, int, int]]) -> None:
    for element_type, semantic, _index in elements:
        if semantic == SEM_POSITION:
            writer.vec3(vertex.position)
        elif semantic == SEM_NORMAL:
            writer.vec3(vertex.normal)
        elif semantic == SEM_COLOR:
            writer.bytes(bytes(vertex.color))
        elif semantic == SEM_TEXCOORD:
            writer.vec2(vertex.uv)
        elif semantic == SEM_TANGENT:
            writer.vec4(vertex.tangent)
        elif semantic == SEM_LIGHTMAPUV:
            writer.vec2(vertex.uv2)
        else:
            raise ValueError(f"unsupported vertex semantic {semantic}")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export current/opened Blender scene to UrhoX scene resources")
    parser.add_argument("--blend", help="Optional .blend file to open before exporting")
    parser.add_argument("--out-dir", required=True, help="Output scene resource directory, for example /workspace/assets/blender/MyScene")
    parser.add_argument("--scene-id", required=True, help="Scene id/name used for Scene.xml and default resource prefix")
    parser.add_argument("--resource-prefix", default=None, help="Resource prefix written into XML references; default: blender/<scene-id>")
    parser.add_argument("--strict-shader", action="store_true", help="Treat unsupported/complex shader graph inputs as export errors")
    parser.add_argument("--only-selected", action="store_true", help="Export only selected Blender objects")
    parser.add_argument("--include-disabled", dest="skip_disabled", action="store_false", help="Include hidden/render-disabled objects")
    parser.set_defaults(skip_disabled=True)
    parser.add_argument("--no-cameras", action="store_true", help="Do not export cameras")
    parser.add_argument("--no-lights", action="store_true", help="Do not export lights")
    parser.add_argument("--flip-v", action="store_true", help="Flip V component of UVs during export")
    return parser.parse_args(argv)


def blender_script_args() -> Sequence[str]:
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    return sys.argv[1:]


def main() -> int:
    args = parse_args(blender_script_args())
    exporter = UrhoXExporter(args)
    return exporter.run()


if __name__ == "__main__":
    raise SystemExit(main())
