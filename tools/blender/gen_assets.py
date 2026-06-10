"""Headless Blender asset generator for Binder Builder.

Generates the app's 3D assets (.usdz, RealityKit conventions: meters, Y-up)
plus 2D resources (cardback.png, studio.exr).

Usage:
    Blender --background --python tools/blender/gen_assets.py -- \
        --out binderBuilder/Assets3D --resources binderBuilder/Resources \
        [--only Binder]

Requires Blender 5.x (USD exporter with convert_orientation / usdz support).
"""

import argparse
import math
import os
import sys

import bpy
import numpy as np

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------


def clear_scene():
    """Start from a completely empty scene (also resets materials/meshes)."""
    bpy.ops.wm.read_homefile(use_empty=True)


def select_only(obj):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def pbr(name, color, rough=0.5, metal=0.0, alpha=1.0, transmission=0.0):
    """Plain principled material. Colors are linear RGB tuples."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    bsdf.inputs["Alpha"].default_value = alpha
    if transmission and "Transmission Weight" in bsdf.inputs:
        bsdf.inputs["Transmission Weight"].default_value = transmission
    if alpha < 1.0:
        # Viewport/EEVEE hints only; USD preview surface gets `opacity` from Alpha.
        for attr, val in (("blend_method", "BLEND"),
                          ("surface_render_method", "BLENDED")):
            try:
                setattr(m, attr, val)
            except Exception:
                pass
    return m


def box(name, size, loc=(0, 0, 0), rot=None, mat=None,
        bevel=0.002, bevel_segments=3):
    """Beveled rectangular box. size=(x,y,z) full extents, loc = center."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.active_object
    o.name = name
    o.scale = size
    select_only(o)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if rot is not None:
        o.rotation_euler = rot
    if bevel > 0:
        # Clamp so the bevel never exceeds half the smallest extent.
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = min(bevel, 0.45 * min(size))
        b.segments = bevel_segments
        b.limit_method = 'ANGLE'
        b.angle_limit = math.radians(30)
    if mat is not None:
        o.data.materials.append(mat)
    return o


def torus(name, major, minor, loc=(0, 0, 0), rot=(0, 0, 0), mat=None,
          major_segments=48, minor_segments=16):
    bpy.ops.mesh.primitive_torus_add(
        major_radius=major, minor_radius=minor, location=loc, rotation=rot,
        major_segments=major_segments, minor_segments=minor_segments)
    o = bpy.context.active_object
    o.name = name
    select_only(o)
    bpy.ops.object.shade_smooth()
    if mat is not None:
        o.data.materials.append(mat)
    return o


def cylinder(name, radius, depth, loc=(0, 0, 0), rot=(0, 0, 0), mat=None,
             vertices=32):
    bpy.ops.mesh.primitive_cylinder_add(
        radius=radius, depth=depth, location=loc, rotation=rot,
        vertices=vertices)
    o = bpy.context.active_object
    o.name = name
    select_only(o)
    bpy.ops.object.shade_smooth()
    if mat is not None:
        o.data.materials.append(mat)
    return o


def finalize_scene():
    """Apply all modifiers and all transforms on every mesh object."""
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    for o in meshes:
        select_only(o)
        bpy.ops.object.convert(target='MESH')  # applies modifiers
    bpy.ops.object.select_all(action='DESELECT')
    for o in meshes:
        o.select_set(True)
    if meshes:
        bpy.context.view_layer.objects.active = meshes[0]
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def _usd_export(filepath):
    bpy.ops.wm.usd_export(
        filepath=filepath,
        check_existing=False,
        selected_objects_only=False,
        export_animation=False,
        export_materials=True,
        generate_preview_surface=True,
        generate_materialx_network=False,
        convert_orientation=True,
        export_global_forward_selection='NEGATIVE_Z',
        export_global_up_selection='Y',
        convert_scene_units='METERS',
        export_lights=False,
        export_cameras=False,
        convert_world_material=False,
        evaluation_mode='RENDER',
    )


def export_usdz(path, opacity_overrides=None):
    """Export the whole scene as .usdz: meters, Y-up, -Z forward (RealityKit).

    opacity_overrides: {material_name: opacity} — Blender 5's USD exporter
    does not write the Principled BSDF's constant Alpha to UsdPreviewSurface
    `opacity` (and maps Transmission to opacity=0), so transparency must be
    patched into the exported stage via the pxr API before packaging.
    """
    finalize_scene()
    if not opacity_overrides:
        _usd_export(path)
    else:
        from pxr import Usd, UsdShade, Sdf, UsdUtils
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            usdc = os.path.join(tmp, os.path.basename(path).replace(".usdz", ".usdc"))
            _usd_export(usdc)
            stage = Usd.Stage.Open(usdc)
            patched = []
            for prim in stage.Traverse():
                if prim.GetTypeName() != "Shader":
                    continue
                shader = UsdShade.Shader(prim)
                if shader.GetIdAttr().Get() != "UsdPreviewSurface":
                    continue
                mat_name = prim.GetParent().GetName()
                if mat_name in opacity_overrides:
                    shader.CreateInput("opacity", Sdf.ValueTypeNames.Float).Set(
                        float(opacity_overrides[mat_name]))
                    patched.append(mat_name)
            missing = set(opacity_overrides) - set(patched)
            if missing:
                raise RuntimeError(f"opacity override targets not found: {missing}")
            stage.GetRootLayer().Save()
            if not UsdUtils.CreateNewUsdzPackage(usdc, path):
                raise RuntimeError(f"usdz packaging failed for {path}")
            print(f"patched opacity on {patched} in {os.path.basename(path)}")
    print(f"exported {path} ({os.path.getsize(path)} bytes)")


# ---------------------------------------------------------------------------
# Shared materials / dimensions
# ---------------------------------------------------------------------------

# Binder: 0.32 m tall (page direction) x 0.26 m wide x 0.05 m thick.
BINDER_W = 0.26   # cover width (hinge -> open edge)
BINDER_H = 0.32   # cover height (page direction)
BINDER_D = 0.05   # closed thickness
COVER_T = 0.005   # cover board thickness

# Colors are linear RGB; keep them deep/saturated — tone mapping lifts them.
LEATHER = dict(color=(0.115, 0.012, 0.018), rough=0.55)
GOLD = dict(color=(0.72, 0.46, 0.12), rough=0.28, metal=1.0)
STEEL = dict(color=(0.80, 0.82, 0.85), rough=0.25, metal=1.0)
PAPER = dict(color=(0.74, 0.70, 0.60), rough=0.8)


def add_cover_emblem(mat_gold, center, z_top):
    """Small gold diamond emblem inlaid on a cover (matches the card back)."""
    box("Emblem", (0.055, 0.055, 0.0012),
        loc=(center[0], center[1], z_top),
        rot=(0, 0, math.radians(45)),
        mat=mat_gold, bevel=0.0004, bevel_segments=2)


def ring_assembly(mat_steel, z_plate_bottom, ring_major=0.017):
    """Spine-mounted 3-ring mechanism: base plate + 3 upright rings (+Z up)."""
    plate_t = 0.004
    box("RingPlate", (0.028, BINDER_H - 0.03, plate_t),
        loc=(0, 0, z_plate_bottom + plate_t / 2),
        mat=mat_steel, bevel=0.0014, bevel_segments=2)
    for i, y in enumerate((-0.105, 0.0, 0.105)):
        torus(f"Ring{i}", ring_major, 0.0028,
              loc=(0, y, z_plate_bottom + plate_t + ring_major * 0.72),
              rot=(math.pi / 2, 0, 0), mat=mat_steel)


# ---------------------------------------------------------------------------
# Asset builders (each starts from an empty scene)
# ---------------------------------------------------------------------------


def build_binder():
    """Closed ring binder, lying flat, origin at geometric center."""
    leather = pbr("Leather", **LEATHER)
    leather_dark = pbr("LeatherDark", color=(0.082, 0.009, 0.013), rough=0.6)
    gold = pbr("Gold", **GOLD)
    steel = pbr("Steel", **STEEL)
    paper = pbr("Paper", **PAPER)

    # Covers parallel to the ground (XY plane), spine on -X edge.
    z_back = -BINDER_D / 2 + COVER_T / 2
    z_front = BINDER_D / 2 - COVER_T / 2
    box("BackCover", (BINDER_W, BINDER_H, COVER_T), loc=(0, 0, z_back),
        mat=leather, bevel=0.0018, bevel_segments=3)
    box("FrontCover", (BINDER_W, BINDER_H, COVER_T), loc=(0, 0, z_front),
        mat=leather, bevel=0.0018, bevel_segments=3)
    # Spine closes the -X edge, full thickness.
    box("Spine", (COVER_T, BINDER_H, BINDER_D),
        loc=(-BINDER_W / 2 + COVER_T / 2, 0, 0),
        mat=leather_dark, bevel=0.0018, bevel_segments=3)
    # Page block peeking out between the covers.
    box("Pages", (BINDER_W - 0.02, BINDER_H - 0.014, BINDER_D - 2 * COVER_T - 0.004),
        loc=(0.004, 0, 0), mat=paper, bevel=0.0012, bevel_segments=2)
    # Hidden ring mechanism along the spine (between the pages and spine).
    for i, y in enumerate((-0.105, 0.0, 0.105)):
        torus(f"Ring{i}", 0.012, 0.002,
              loc=(-BINDER_W / 2 + 0.018, y, 0),
              rot=(math.pi / 2, 0, 0), mat=steel)
    # Gold diamond emblem on the front cover.
    add_cover_emblem(gold, (0.012, 0), BINDER_D / 2)


def build_binder_open():
    """Binder open flat on the ground, origin at spine center on the ground."""
    leather = pbr("Leather", **LEATHER)
    liner = pbr("Liner", color=(0.50, 0.43, 0.31), rough=0.75)
    steel = pbr("Steel", **STEEL)

    spine_w = BINDER_D  # the closed thickness becomes the flat spine width
    zc = COVER_T / 2    # boards lie on the ground plane
    box("Spine", (spine_w, BINDER_H, COVER_T), loc=(0, 0, zc),
        mat=leather, bevel=0.0018, bevel_segments=3)
    for side, name in ((-1, "LeftCover"), (1, "RightCover")):
        x = side * (spine_w / 2 + BINDER_W / 2 - 0.002)
        box(name, (BINDER_W, BINDER_H, COVER_T), loc=(x, 0, zc),
            mat=leather, bevel=0.0018, bevel_segments=3)
        # Paper liner inset on the inside (top) face of each cover.
        box(name + "Liner", (BINDER_W - 0.024, BINDER_H - 0.024, 0.0014),
            loc=(x, 0, COVER_T + 0.0005),
            mat=liner, bevel=0.0005, bevel_segments=2)
    # Upright ring mechanism on the spine.
    ring_assembly(steel, z_plate_bottom=COVER_T)


def build_shelf():
    """Wall-mounted wooden display shelf, ~1.2 m wide, origin back-bottom.

    Back panel sits on the y=0 plane; the shelf extends toward -Y in Blender
    space, which becomes +Z (toward the viewer) after the Y-up export.
    """
    wood = pbr("Wood", color=(0.155, 0.078, 0.035), rough=0.55)
    wood_light = pbr("WoodLight", color=(0.21, 0.115, 0.055), rough=0.5)

    W, D, H = 1.2, 0.26, 0.72
    side_t, back_t, slab_t = 0.02, 0.016, 0.028

    # Back panel against the wall (y in [-back_t, 0]).
    box("Back", (W, back_t, H), loc=(0, -back_t / 2, H / 2),
        mat=wood, bevel=0.003, bevel_segments=2)
    # Full-height side panels.
    for side, name in ((-1, "SideL"), (1, "SideR")):
        box(name, (side_t, D - back_t, H),
            loc=(side * (W / 2 - side_t / 2), -back_t - (D - back_t) / 2, H / 2),
            mat=wood, bevel=0.003, bevel_segments=2)
    # Two horizontal slabs spanning between the sides.
    inner_w = W - 2 * side_t + 0.004
    for z_bottom, name in ((0.0, "ShelfLow"), (0.42, "ShelfHigh")):
        box(name, (inner_w, D - back_t, slab_t),
            loc=(0, -back_t - (D - back_t) / 2, z_bottom + slab_t / 2),
            mat=wood_light, bevel=0.003, bevel_segments=2)
    # Slim top rail to finish the silhouette.
    box("TopRail", (W, D - back_t, 0.02),
        loc=(0, -back_t - (D - back_t) / 2, H + 0.01),
        mat=wood_light, bevel=0.003, bevel_segments=2)


def build_glass_case():
    """Card display case 0.09 x 0.12 x 0.03 m: wood base + glass box.

    NOTE: UsdPreviewSurface has no transmission input. Blender's USD
    exporter maps Transmission Weight 1.0 to `opacity = 0` (fully
    invisible), so the glass deliberately uses Alpha-only transparency
    (exports as opacity 0.15).
    """
    wood = pbr("BaseWood", color=(0.085, 0.042, 0.02), rough=0.5)
    glass = pbr("Glass", color=(0.82, 0.90, 0.94), rough=0.05,
                alpha=0.15, transmission=0.0)
    backing = pbr("Backing", color=(0.62, 0.62, 0.65), rough=0.6)

    W, H, D = 0.09, 0.12, 0.03
    base_h = 0.016
    box("Base", (W, D, base_h), loc=(0, 0, base_h / 2),
        mat=wood, bevel=0.0025, bevel_segments=3)
    # Glass enclosure (slightly inset on the base).
    gw, gd, gh = W - 0.008, D - 0.007, H - base_h - 0.002
    box("Glass", (gw, gd, gh), loc=(0, 0, base_h + gh / 2),
        mat=glass, bevel=0.0015, bevel_segments=2)
    # Card backing plate inside, so transparency reads in renders.
    box("Backing", (gw - 0.014, 0.0025, gh - 0.014),
        loc=(0, gd / 2 - 0.006, base_h + gh / 2),
        mat=backing, bevel=0.0006, bevel_segments=2)
    return {"Glass": 0.15}  # patched into the USD after export (see export_usdz)


def build_card_stand():
    """Small easel-style card stand: two back legs + front rail with a lip."""
    wood = pbr("DarkWood", color=(0.055, 0.032, 0.018), rough=0.45)

    leg_h, leg_s = 0.078, 0.0065
    tilt = math.radians(-16)  # lean the tops backwards (+Y)
    for side, name in ((-1, "LegL"), (1, "LegR")):
        box(name, (leg_s, leg_s, leg_h),
            loc=(side * 0.029, 0.009 + math.sin(-tilt) * leg_h / 2,
                 math.cos(tilt) * leg_h / 2),
            rot=(tilt, 0, 0), mat=wood, bevel=0.0012, bevel_segments=2)
    # Cross bar between the legs (the card leans against it). Slightly
    # narrower than the leg span so its ends sit inside the legs (no
    # coplanar faces).
    box("CrossBar", (0.054, leg_s * 0.75, 0.008),
        loc=(0, 0.009 + math.sin(-tilt) * leg_h * 0.76,
             math.cos(tilt) * leg_h * 0.76),
        rot=(tilt, 0, 0), mat=wood, bevel=0.0012, bevel_segments=2)
    # Base rail at the front + raised lip that holds the card's bottom edge.
    box("BaseRail", (0.068, 0.017, 0.006), loc=(0, -0.0055, 0.003),
        mat=wood, bevel=0.0012, bevel_segments=2)
    box("Lip", (0.068, 0.0035, 0.012), loc=(0, -0.0125, 0.009),
        mat=wood, bevel=0.001, bevel_segments=2)


ASSETS = {
    "Binder": build_binder,
    "BinderOpen": build_binder_open,
    "Shelf": build_shelf,
    "GlassCase": build_glass_case,
    "CardStand": build_card_stand,
}


# ---------------------------------------------------------------------------
# 2D resources: card back PNG + studio environment EXR
# ---------------------------------------------------------------------------


def _srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _save_byte_png(path, rgb_srgb):
    """rgb_srgb: (H, W, 3) float array of intended sRGB display values,
    row 0 = top. Blender stores byte-image pixels via a linear->sRGB encode,
    so we feed linearized values."""
    h, w, _ = rgb_srgb.shape
    rgba = np.ones((h, w, 4), dtype=np.float32)
    rgba[:, :, :3] = _srgb_to_linear(np.clip(rgb_srgb, 0.0, 1.0))
    rgba = np.flipud(rgba)  # bpy pixel rows start at the bottom
    img = bpy.data.images.new("gen_png", w, h, alpha=False)
    img.pixels.foreach_set(rgba.ravel().astype(np.float32))
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    bpy.data.images.remove(img)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def _stroke(dist, half_width, aa=1.4):
    """Anti-aliased band mask around the dist==0 contour."""
    return np.clip((half_width - np.abs(dist)) / aa + 1.0, 0.0, 1.0)


def _fill(dist, aa=1.4):
    return np.clip(-dist / aa + 0.5, 0.0, 1.0)


def _rrect_sdf(nx, ny, hw, hh, r):
    qx = np.abs(nx) - (hw - r)
    qy = np.abs(ny) - (hh - r)
    return (np.hypot(np.maximum(qx, 0), np.maximum(qy, 0))
            + np.minimum(np.maximum(qx, qy), 0) - r)


def build_cardback(path):
    """Original card-back: deep blue, gold double border + diamond, and a
    silver three-ring (binder rings) motif. Purely geometric — no resemblance
    to any existing card back."""
    W, H = 600, 825
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    nx, ny = xx - W / 2 + 0.5, yy - H / 2 + 0.5
    r_norm = np.hypot(nx / (W / 2), ny / (H / 2))

    # Background: deep blue with a vignette and a faint diagonal lattice.
    base = np.array([0.10, 0.17, 0.42], dtype=np.float32)
    img = np.empty((H, W, 3), dtype=np.float32)
    img[:] = base
    img *= (1.0 - 0.22 * np.clip(r_norm, 0, 1.2) ** 2)[..., None]
    lattice = (np.abs(((xx + yy) % 56) - 28) < 1.0) | \
              (np.abs(((xx - yy) % 56) - 28) < 1.0)
    img += lattice[..., None].astype(np.float32) * 0.03

    gold = np.array([0.80, 0.63, 0.30], dtype=np.float32)
    gold_dim = np.array([0.55, 0.44, 0.22], dtype=np.float32)
    silver = np.array([0.76, 0.79, 0.84], dtype=np.float32)

    def paint(alpha, color):
        nonlocal img
        img = img * (1 - alpha[..., None]) + color * alpha[..., None]

    # Double border frame.
    paint(_stroke(_rrect_sdf(nx, ny, W / 2 - 26, H / 2 - 26, 18), 3.0), gold)
    paint(_stroke(_rrect_sdf(nx, ny, W / 2 - 42, H / 2 - 42, 12), 1.2), gold_dim)

    # Center diamond: soft fill, then double outline.
    diamond = (np.abs(nx) + np.abs(ny) * (W / H)) / math.sqrt(2)
    paint(_fill(diamond - 158) * 0.22, np.array([0.18, 0.28, 0.56], np.float32))
    paint(_stroke(diamond - 158, 3.0), gold)
    paint(_stroke(diamond - 172, 1.2), gold_dim)

    # Three-ring motif (vertical column, like binder rings).
    for cy in (-92.0, 0.0, 92.0):
        d = np.hypot(nx, ny - cy) - 33.0
        paint(_stroke(d, 4.0), silver)
        paint(_stroke(np.hypot(nx, ny - cy) - 25.0, 1.0), gold_dim * 0.9)

    # Small filled corner diamonds.
    for sx in (-1, 1):
        for sy in (-1, 1):
            cdx, cdy = nx - sx * (W / 2 - 64), ny - sy * (H / 2 - 64)
            paint(_fill((np.abs(cdx) + np.abs(cdy)) / math.sqrt(2) - 9), gold)

    _save_byte_png(path, img)


def build_studio_exr(path):
    """Small equirectangular studio HDR: gradient sky + softbox rectangles.
    512x256, half-float ZIP EXR, scene-linear values (well under 1 MB)."""
    W, H = 512, 256
    row = np.arange(H, dtype=np.float32) + 0.5     # row 0 = bottom (bpy order)
    col = np.arange(W, dtype=np.float32) + 0.5
    theta = (row / H) * math.pi - math.pi / 2       # -pi/2 nadir .. +pi/2 zenith
    phi = (col / W) * 2 * math.pi - math.pi         # -pi .. pi
    T, P = np.meshgrid(theta, phi, indexing='ij')

    img = np.empty((H, W, 3), dtype=np.float32)
    up = np.clip(T / (math.pi / 2), -1, 1)
    sky_lo = np.array([0.16, 0.175, 0.21])
    sky_hi = np.array([0.34, 0.385, 0.48])
    floor_lo = np.array([0.115, 0.105, 0.095])
    floor_hi = np.array([0.155, 0.150, 0.145])
    t = np.abs(up)[..., None]
    img[:] = np.where(up[..., None] >= 0,
                      sky_lo * (1 - t) + sky_hi * t,
                      floor_hi * (1 - t) + floor_lo * t).astype(np.float32)

    def softbox(c_phi, c_theta, half_u, half_v, color, soft=0.10):
        d_phi = np.abs(((P - c_phi + math.pi) % (2 * math.pi)) - math.pi)
        d_the = np.abs(T - c_theta)
        m = (np.clip((half_u - d_phi) / soft + 1, 0, 1)
             * np.clip((half_v - d_the) / soft + 1, 0, 1))
        return m[..., None] * np.asarray(color, dtype=np.float32)

    img += softbox(-1.5, 0.66, 0.50, 0.26, (7.5, 7.2, 6.8))      # key
    img += softbox(1.25, 0.46, 0.38, 0.20, (2.6, 2.8, 3.3))      # fill
    img += softbox(3.05, 0.62, 0.26, 0.16, (4.0, 4.3, 4.9))      # rim

    rgba = np.ones((H, W, 4), dtype=np.float32)
    rgba[:, :, :3] = img
    eimg = bpy.data.images.new("gen_exr", W, H, alpha=False, float_buffer=True)
    eimg.pixels.foreach_set(rgba.ravel())
    scene = bpy.context.scene
    scene.render.image_settings.file_format = 'OPEN_EXR'
    scene.render.image_settings.exr_codec = 'ZIP'
    scene.render.image_settings.color_depth = '16'
    scene.render.image_settings.color_mode = 'RGB'
    eimg.save_render(filepath=path, scene=scene)
    bpy.data.images.remove(eimg)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


RESOURCES = {
    "cardback": ("cardback.png", build_cardback),
    "studio": ("studio.exr", build_studio_exr),
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser(prog="gen_assets.py")
    ap.add_argument("--out", required=True, help="output dir for .usdz files")
    ap.add_argument("--resources", default=None,
                    help="output dir for cardback.png / studio.exr")
    ap.add_argument("--only", default=None,
                    help="generate a single asset (e.g. Binder, cardback)")
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    if args.resources:
        os.makedirs(args.resources, exist_ok=True)

    names = list(ASSETS) + (list(RESOURCES) if args.resources else [])
    if args.only:
        if args.only not in names:
            ap.error(f"unknown asset {args.only!r}; choose from {names}")
        names = [args.only]

    for name in names:
        if name in ASSETS:
            clear_scene()
            opacity_overrides = ASSETS[name]()  # builders may return overrides
            export_usdz(os.path.join(args.out, f"{name}.usdz"), opacity_overrides)
        else:
            filename, fn = RESOURCES[name]
            fn(os.path.join(args.resources, filename))

    print("gen_assets: done")


if __name__ == "__main__":
    main()
