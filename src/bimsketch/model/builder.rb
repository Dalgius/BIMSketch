# frozen_string_literal: true

module BIMSketch
  # Creazione degli elementi BIM parametrici (unità interne SketchUp).
  # Tutti i metodi vanno chiamati all'interno di un'operazione del modello.
  module Builder
    module_function

    def level_id(model)
      Levels.current(model)['id']
    end

    def finish(model, group, type_key, params = {}, level: nil)
      BimData.classify(group, type_key, level: level || level_id(model))
      group.set_attribute(BimData::DICT, 'parametric', true)
      params.each { |k, v| group.set_attribute(BimData::DICT, k.to_s, v) }
      group
    end

    # Muro da p1 a p2 (stessa quota), con spessore, altezza e allineamento
    # ('center', 'left', 'right' rispetto alla direzione di disegno).
    # ext_start/ext_end prolungano (o accorciano, se negativi) il muro agli estremi.
    def wall(model, p1, p2, thickness, height, align = 'center', ext_start: 0, ext_end: 0)
      dir = p2 - p1
      dir.z = 0
      return nil if dir.length < Geometry::TOL

      xaxis = dir.normalize
      yaxis = Z_AXIS * xaxis
      offset = case align
               when 'left' then 0
               when 'right' then -thickness
               else -thickness / 2.0
               end
      origin = p1.offset(yaxis, offset)
      origin = origin.offset(xaxis, -ext_start) unless ext_start.zero?
      length = dir.length + ext_start + ext_end
      tr = Geometry.frame_transform(origin, xaxis)
      group = Geometry.create_group(model, tr) { |ents| Geometry.box(ents, length, thickness, height) }
      finish(model, group, 'wall', { 'wall_align' => align })
    end

    # Solaio da un poligono (punti mondo); la faccia superiore sta alla quota top_z.
    def slab(model, points, thickness, top_z, holes: [], type_key: 'slab')
      prism_element(model, points, holes, top_z - thickness, thickness, type_key)
    end

    # Elemento prismatico generico: poligono proiettato a base_z, estruso di height.
    def prism_element(model, points, holes, base_z, height, type_key)
      pts = points.map { |p| Geom::Point3d.new(p.x, p.y, base_z) }
      return nil if pts.size < 3

      min_x = pts.map(&:x).min
      min_y = pts.map(&:y).min
      origin = Geom::Point3d.new(min_x, min_y, base_z)
      tr = Geom::Transformation.translation(origin)
      inv = tr.inverse
      local = pts.map { |p| p.transform(inv) }
      local_holes = holes.map { |h| h.map { |p| Geom::Point3d.new(p.x, p.y, base_z).transform(inv) } }
      group = Geometry.create_group(model, tr) do |ents|
        Geometry.prism(ents, local, local_holes, height)
      end
      finish(model, group, type_key)
    end

    # Pilastro rettangolare centrato in center (base alla quota di center).
    def column(model, center, width, depth, height, rotation = 0.0)
      xaxis = Geom::Vector3d.new(Math.cos(rotation), Math.sin(rotation), 0)
      tr0 = Geometry.frame_transform(center, xaxis)
      origin = Geom::Point3d.new(-width / 2.0, -depth / 2.0, 0).transform(tr0)
      tr = Geometry.frame_transform(origin, xaxis)
      group = Geometry.create_group(model, tr) { |ents| Geometry.box(ents, width, depth, height) }
      finish(model, group, 'column')
    end

    # Trave da p1 a p2 con estradosso (faccia superiore) alla quota top_z.
    def beam(model, p1, p2, width, height, top_z)
      a = Geom::Point3d.new(p1.x, p1.y, top_z - height)
      b = Geom::Point3d.new(p2.x, p2.y, top_z - height)
      dir = b - a
      return nil if dir.length < Geometry::TOL

      xaxis = dir.normalize
      origin = a.offset(Z_AXIS * xaxis, -width / 2.0)
      tr = Geometry.frame_transform(origin, xaxis)
      group = Geometry.create_group(model, tr) { |ents| Geometry.box(ents, dir.length, width, height) }
      finish(model, group, 'beam')
    end

    # Verifica se l'entità è un muro parametrico utilizzabile per le aperture.
    def parametric_wall?(entity)
      BimData.element?(entity) && BimData.type_key(entity) == 'wall' &&
        entity.get_attribute(BimData::DICT, 'parametric') == true
    end

    OPENING_GAP = 10.mm

    # Aperture già presenti nel muro (coordinate locali).
    def wall_openings(wall)
      raw = wall.get_attribute(BimData::DICT, 'openings')
      raw ? JSON.parse(raw) : []
    rescue JSON::ParserError
      []
    end

    # Il muro è ancora il box parametrico con le sue aperture? (se è stato
    # modificato a mano la ricostruzione ne perderebbe le modifiche)
    def wall_intact?(wall)
      bb = wall.definition.bounds
      det = Geometry.scales(wall.transformation).reduce(:*)
      vol = wall.volume
      return false unless vol > 0 && det > 0

      expected = WallProfile.net_volume(bb.min.x, bb.max.x, bb.min.y, bb.max.y, bb.min.z, bb.max.z,
                                        wall_openings(wall))
      (vol / det - expected).abs <= [expected * 0.001, 1.0].max
    end

    # Calcola il rettangolo dell'apertura (coordinate locali del muro).
    # Restituisce [a, b, c, d] oppure nil se non entra nel muro o si
    # sovrappone a un'altra apertura.
    def opening_rect(wall, local_x, width, height, sill)
      sx, _sy, sz = Geometry.scales(wall.transformation)
      bb = wall.definition.bounds
      x0 = bb.min.x.to_f
      x1 = bb.max.x.to_f
      z0 = bb.min.z.to_f
      w = width.to_f / sx
      h = height.to_f / sz
      c = z0 + sill.to_f / sz
      local_x = local_x.to_f
      gap = OPENING_GAP / sx
      door = sill <= Geometry::TOL
      margin = door ? 0 : gap
      return nil if w > (x1 - x0) - 2 * margin || c + h > bb.max.z - OPENING_GAP / sz

      a = [[local_x - w / 2.0, x0 + margin].max, x1 - margin - w].min
      rect = [a, a + w, c, c + h].map(&:to_f)
      return nil if WallProfile.overlaps?(rect, wall_openings(wall), gap)

      rect
    end

    # Inserisce una porta o una finestra in un muro parametrico: taglia il
    # foro nel muro e crea l'elemento nel vano.
    def opening(model, wall, kind, local_x, width, height, sill)
      rect = opening_rect(wall, local_x, width, height, sill)
      return nil unless rect

      raise "il muro è stato modificato a mano: non è possibile inserire l'apertura" unless wall_intact?(wall)

      a, b, c, d = rect
      openings = wall_openings(wall) + [rect]
      Geometry.rebuild_wall(wall, openings)
      wall.set_attribute(BimData::DICT, 'openings', JSON.generate(openings))
      wall_tr = wall.transformation
      t = wall.definition.bounds.max.y
      _sx, sy, = Geometry.scales(wall_tr)
      depth = [kind == 'door' ? 50.mm : 80.mm, t * sy].min
      origin = Geom::Point3d.new(a, t / 2.0, c).transform(wall_tr)
      xaxis = X_AXIS.transform(wall_tr)
      world_origin = origin.offset(Z_AXIS * xaxis.normalize, -depth / 2.0)
      tr = Geometry.frame_transform(world_origin, xaxis)
      # Il muro può trovarsi nel contesto attivo: le coordinate sono già quelle del contesto.
      tr = model.edit_transform * tr if model.active_path
      w_world = (b - a) * Geometry.scales(wall_tr)[0]
      h_world = (d - c) * Geometry.scales(wall_tr)[2]
      group = Geometry.create_group(model, tr) do |ents|
        if kind == 'door'
          Geometry.box(ents, w_world, depth, h_world)
        else
          build_window(model, ents, w_world, depth, h_world)
        end
      end
      finish(model, group, kind, { 'host' => BimData.guid(wall) }, level: BimData.level_id(wall))
      external = BimData.json_attr(wall, 'props')['IsExternal']
      unless external.nil?
        props = BimData.json_attr(group, 'props').merge('IsExternal' => external)
        group.set_attribute(BimData::DICT, 'props', JSON.generate(props))
      end
      group
    end

    def build_window(model, ents, width, depth, height)
      profile = [60.mm, [width, height].min / 4.0].min
      Geometry.frame(ents, width, height, profile, depth)
      glass = ents.add_group
      g_depth = 8.mm
      g_tr = Geom::Transformation.translation([profile, (depth - g_depth) / 2.0, profile])
      Geometry.box(glass.entities, width - 2 * profile, g_depth, height - 2 * profile)
      glass.transformation = g_tr
      glass.material = glass_material(model)
      glass
    end

    def glass_material(model)
      mat = model.materials['BIM Vetro']
      return mat if mat

      mat = model.materials.add('BIM Vetro')
      mat.color = Sketchup::Color.new(150, 200, 235)
      mat.alpha = 0.35
      mat
    end
  end
end
