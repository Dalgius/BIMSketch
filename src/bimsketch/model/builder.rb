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

    # Sistema locale e lunghezza di un muro da p1 a p2 (coordinate mondo).
    def wall_frame(p1, p2, thickness, align, ext_start, ext_end)
      dir = p2 - p1
      dir.z = 0
      return nil if dir.length < Geometry::TOL

      xaxis = dir.normalize
      lo, = WallJoint.band(align, thickness.to_f)
      origin = Geom::Point3d.new(p1.x, p1.y, p1.z)
      origin = origin.offset(Z_AXIS * xaxis, lo) unless lo.zero?
      origin = origin.offset(xaxis, -ext_start) unless ext_start.zero?
      [Geometry.frame_transform(origin, xaxis), dir.length + ext_start + ext_end]
    end

    # Muro da p1 a p2 (stessa quota), con spessore, altezza e allineamento
    # ('center', 'left', 'right' rispetto alla direzione di disegno).
    # ext_start/ext_end prolungano (o accorciano, se negativi) il muro agli estremi.
    def wall(model, p1, p2, thickness, height, align = 'center', ext_start: 0, ext_end: 0)
      frame = wall_frame(p1, p2, thickness, align, ext_start.to_f, ext_end.to_f)
      return nil unless frame

      tr, length = frame
      group = Geometry.create_group(model, tr) { |ents| Geometry.box(ents, length, thickness, height) }
      finish(model, group, 'wall', { 'wall_align' => align,
                                     'ext' => JSON.generate([ext_start.to_f, ext_end.to_f]) })
    end

    # Parametri di un muro parametrico ricavati dalla sua geometria: estremi
    # dell'asse (coordinate mondo, senza prolungamenti), spessore, altezza,
    # allineamento e prolungamenti. nil se non è un muro parametrico.
    def wall_params(model, wall)
      return nil unless parametric_wall?(wall)

      ext = begin
        JSON.parse(wall.get_attribute(BimData::DICT, 'ext') || '[0,0]').map(&:to_f)
      rescue JSON::ParserError
        [0.0, 0.0]
      end
      bb = wall.definition.bounds
      sx, sy, sz = Geometry.scales(wall.transformation)
      align = wall.get_attribute(BimData::DICT, 'wall_align') || 'center'
      local_t = bb.max.y - bb.min.y
      lo, = WallJoint.band(align, local_t.to_f)
      world = model.active_path ? model.edit_transform * wall.transformation : wall.transformation
      axis_y = bb.min.y - lo
      p1 = Geom::Point3d.new(bb.min.x + ext[0] / sx, axis_y, bb.min.z).transform(world)
      p2 = Geom::Point3d.new(bb.max.x - ext[1] / sx, axis_y, bb.min.z).transform(world)
      { p1: p1, p2: p2, thickness: local_t * sy, height: (bb.max.z - bb.min.z) * sz,
        align: align, ext: ext }
    end

    # Ricostruisce un muro esistente con nuovi prolungamenti, mantenendo gruppo,
    # GlobalId e proprietà. Solo per muri senza aperture e non modificati a mano.
    def reshape_wall(model, wall, ext_start, ext_end)
      pr = wall_params(model, wall)
      return false unless pr && wall_openings(wall).empty? && wall_intact?(wall)

      frame = wall_frame(pr[:p1], pr[:p2], pr[:thickness], pr[:align], ext_start, ext_end)
      return false unless frame

      tr, length = frame
      tr = model.edit_transform.inverse * tr if model.active_path
      wall.make_unique if wall.respond_to?(:make_unique)
      ents = wall.definition.entities
      ents.clear!
      Geometry.box(ents, length, pr[:thickness], pr[:height])
      wall.transformation = tr
      wall.set_attribute(BimData::DICT, 'ext', JSON.generate([ext_start.to_f, ext_end.to_f]))
      true
    end

    # Estremità di un muro parametrico del contesto attivo vicina al punto
    # (in pianta, stessa quota di base). Restituisce { wall:, at: :p1|:p2, point:, params: }.
    def wall_end_near(model, point, tolerance, exclude = nil)
      best = nil
      model.active_entities.each do |e|
        next if e == exclude || !parametric_wall?(e)

        pr = wall_params(model, e)
        next if (pr[:p1].z - point.z).abs > 1.mm

        { p1: pr[:p1], p2: pr[:p2] }.each do |at, q|
          d = Math.hypot(q.x - point.x, q.y - point.y)
          best = [d, { wall: e, at: at, point: q, params: pr }] if d <= tolerance && (best.nil? || d < best[0])
        end
      end
      best && best[1]
    end

    # Raggio entro cui un nuovo muro si aggancia all'estremità di un muro esistente.
    def snap_tolerance(thickness)
      thickness * 1.5
    end

    # Muro da p1 a p2 che si aggancia ai muri esistenti: se un estremo cade
    # vicino all'estremità di un altro muro parametrico, il punto viene
    # portato sull'asse di quel muro e l'angolo viene raccordato (anche il
    # muro esistente viene adattato). Restituisce { wall:, end_point:, joined_end: }.
    def wall_connected(model, p1, p2, thickness, height, align = 'center')
      tol = snap_tolerance(thickness)
      start_hit = wall_end_near(model, p1, tol)
      p1 = start_hit[:point] if start_hit
      end_hit = wall_end_near(model, p2, tol, start_hit && start_hit[:wall])
      p2 = Geom::Point3d.new(end_hit[:point].x, end_hit[:point].y, p1.z) if end_hit
      return nil if Math.hypot(p2.x - p1.x, p2.y - p1.y) < Geometry::TOL

      band_n = WallJoint.band(align, thickness.to_f)
      dir_n = planar_dir(p1, p2)
      ext_start = 0.0
      ext_end = 0.0
      if start_hit
        pr = start_hit[:params]
        band_w = WallJoint.band(pr[:align], pr[:thickness].to_f)
        if start_hit[:at] == :p2
          s, r = WallJoint.corner(planar_dir(pr[:p1], pr[:p2]), dir_n, band_w, band_n)
          ext_start = -r if reshape_wall(model, start_hit[:wall], pr[:ext][0], s)
        else
          s, r = WallJoint.corner(planar_dir(pr[:p2], pr[:p1]), dir_n, WallJoint.flip(band_w), band_n)
          ext_start = -r if reshape_wall(model, start_hit[:wall], s, pr[:ext][1])
        end
      end
      if end_hit
        pr = end_hit[:params]
        band_w = WallJoint.band(pr[:align], pr[:thickness].to_f)
        if end_hit[:at] == :p1
          s, r = WallJoint.corner(dir_n, planar_dir(pr[:p1], pr[:p2]), band_n, band_w)
          ext_end = s if reshape_wall(model, end_hit[:wall], -r, pr[:ext][1])
        else
          s, r = WallJoint.corner(dir_n, planar_dir(pr[:p2], pr[:p1]), band_n, WallJoint.flip(band_w))
          ext_end = s if reshape_wall(model, end_hit[:wall], pr[:ext][0], -r)
        end
      end
      group = wall(model, p1, p2, thickness, height, align, ext_start: ext_start, ext_end: ext_end)
      group && { wall: group, end_point: p2, joined_end: !end_hit.nil? }
    end

    def planar_dir(p, q)
      WallJoint.direction([p.x.to_f, p.y.to_f], [q.x.to_f, q.y.to_f])
    end

    # Sequenza di muri tra i punti indicati (stessa quota), con i giunti
    # d'angolo calcolati da WallJoint. Se closed, l'ultimo punto si ricollega
    # al primo. Restituisce i gruppi creati.
    def wall_chain(model, points, thickness, height, align = 'center', closed: false)
      lo, hi = WallJoint.band(align, thickness.to_f)
      exts = WallJoint.chain(points.map { |p| [p.x.to_f, p.y.to_f] }, lo, hi, closed: closed)
      ends = points.each_cons(2).to_a
      ends << [points.last, points.first] if closed && points.size > 2
      ends.each_with_index.map do |(p1, p2), i|
        wall(model, p1, p2, thickness, height, align, ext_start: exts[i][0], ext_end: exts[i][1])
      end
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
