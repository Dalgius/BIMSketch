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

    # Sistema locale e lunghezza di un muro da p1 a p2 (coordinate mondo):
    # origine sul punto iniziale dell'asse, portata sulla faccia "lo" del muro.
    def wall_frame(p1, p2, thickness, align)
      dir = p2 - p1
      dir.z = 0
      return nil if dir.length < Geometry::TOL

      xaxis = dir.normalize
      lo, = WallJoint.band(align, thickness.to_f)
      origin = Geom::Point3d.new(p1.x, p1.y, p1.z)
      origin = origin.offset(Z_AXIS * xaxis, lo) unless lo.zero?
      [Geometry.frame_transform(origin, xaxis), dir.length]
    end

    # Muro da p1 a p2 (stessa quota), con spessore, altezza e allineamento
    # ('center', 'left', 'right' rispetto alla direzione di disegno).
    # ext: prolungamenti [start_lo, start_hi, end_lo, end_hi] delle due facce
    # (vedi WallJoint), per i giunti a quartabuono con i muri adiacenti.
    # auto_height: l'altezza segue quella del livello (vedi Levels.update).
    # type_id: tipologia con stratigrafia (lo spessore diventa quello della
    # tipologia); flipped: strati percorsi al contrario.
    def wall(model, p1, p2, thickness, height, align = 'center', ext: [0, 0, 0, 0], auto_height: true,
             type_id: nil, flipped: false)
      type = WallTypeLibrary.find(model, type_id)
      thickness = WallTypes.thickness(type).m if type
      frame = wall_frame(p1, p2, thickness, align)
      return nil unless frame

      tr, length = frame
      ext = WallJoint.normalize_ext(ext)
      layers = type ? WallTypeLibrary.geometry_layers(model, type, thickness, flipped) : nil
      group = Geometry.create_group(model, tr) do |ents|
        Geometry.build_wall(ents, length, thickness, height, ext, [], layers: layers)
      end
      finish(model, group, 'wall', { 'wall_align' => align })
      store_wall_geom(group, length: length, thickness: thickness, height: height, align: align, ext: ext,
                             auto: auto_height, type_id: type && type['id'], flipped: flipped)
      apply_type_data(model, group, type) if type
      group
    end

    def store_wall_geom(wall, g)
      geom = { 'length' => g[:length].to_f, 'thickness' => g[:thickness].to_f, 'height' => g[:height].to_f,
               'align' => g[:align], 'ext' => WallJoint.normalize_ext(g[:ext]),
               'auto_height' => g[:auto] == false ? false : true,
               'type_id' => g[:type_id], 'flipped' => g[:flipped] ? true : false }
      wall.set_attribute(BimData::DICT, 'wall_geom', JSON.generate(geom))
      wall.set_attribute(BimData::DICT, 'wall_align', g[:align])
    end

    # Parametri del muro nel suo sistema locale (unità interne, senza scala).
    # I muri delle versioni precedenti (parallelepipedi senza 'wall_geom')
    # vengono letti come muri in asse senza prolungamenti.
    def wall_geom(wall)
      raw = wall.get_attribute(BimData::DICT, 'wall_geom')
      if raw
        g = JSON.parse(raw)
        return { length: g['length'].to_f, thickness: g['thickness'].to_f, height: g['height'].to_f,
                 align: g['align'] || 'center', ext: WallJoint.normalize_ext(g['ext']),
                 auto: g.key?('auto_height') ? g['auto_height'] == true : true,
                 type_id: g['type_id'], flipped: g['flipped'] == true }
      end
      bb = wall.definition.bounds
      { length: (bb.max.x - bb.min.x).to_f, thickness: (bb.max.y - bb.min.y).to_f,
        height: (bb.max.z - bb.min.z).to_f, align: 'center', ext: [0.0, 0.0, 0.0, 0.0], auto: true,
        type_id: nil, flipped: false }
    rescue JSON::ParserError
      nil
    end

    # Tipologia (dalla libreria del modello) assegnata al muro, o nil.
    def wall_type(model, wall)
      g = wall_geom(wall)
      g && WallTypeLibrary.find(model, g[:type_id])
    end

    # Parametri del muro in coordinate mondo: estremi dell'asse, spessore,
    # altezza, allineamento e prolungamenti. nil se non è un muro parametrico.
    def wall_params(model, wall)
      return nil unless parametric_wall?(wall)

      g = wall_geom(wall)
      return nil unless g

      sx, sy, sz = Geometry.scales(wall.transformation)
      lo, = WallJoint.band(g[:align], g[:thickness])
      world = model.active_path ? model.edit_transform * wall.transformation : wall.transformation
      p1 = Geom::Point3d.new(0, -lo, 0).transform(world)
      p2 = Geom::Point3d.new(g[:length], -lo, 0).transform(world)
      { p1: p1, p2: p2, thickness: g[:thickness] * sy, height: g[:height] * sz,
        align: g[:align], ext: g[:ext].map { |e| e * sx } }
    end

    # Ricostruisce un muro esistente (stesso asse) mantenendo gruppo, GlobalId,
    # proprietà e aperture. Si possono cambiare prolungamenti (coordinate
    # mondo), altezza, modalità dell'altezza, tipologia (type_id: nil la
    # toglie) e verso degli strati. Rifiuta i muri modificati a mano o le cui
    # aperture non entrerebbero. Con dry_run verifica soltanto.
    def reshape_wall(model, wall, ext, height: nil, auto: nil, type_id: :keep, flipped: nil, dry_run: false)
      pr = wall_params(model, wall)
      g = wall_geom(wall)
      return false unless pr && g && wall_intact?(wall)

      type_id = g[:type_id] if type_id == :keep
      flipped = g[:flipped] if flipped.nil?
      type = WallTypeLibrary.find(model, type_id)
      thickness = type ? WallTypes.thickness(type).m : pr[:thickness]
      height = (height || pr[:height]).to_f
      return false if height < 0.1.m

      frame = wall_frame(pr[:p1], pr[:p2], thickness, pr[:align])
      return false unless frame

      sx, _sy, sz = Geometry.scales(wall.transformation)
      openings = wall_openings(wall).map { |a, b, c, d| [a * sx, b * sx, c * sz, d * sz] }
      tr, length = frame
      ext = WallJoint.normalize_ext(ext)
      lo_x, hi_x = WallJoint.core_range(length, ext)
      fits = openings.all? do |a, b, _c, d|
        a >= lo_x + OPENING_GAP && b <= hi_x - OPENING_GAP && d <= height - OPENING_GAP
      end
      return false unless fits
      return true if dry_run

      tr = model.edit_transform.inverse * tr if model.active_path
      wall.make_unique if wall.respond_to?(:make_unique)
      ents = wall.definition.entities
      ents.clear!
      layers = type ? WallTypeLibrary.geometry_layers(model, type, thickness, flipped) : nil
      Geometry.build_wall(ents, length, thickness, height, ext, openings, layers: layers)
      wall.transformation = tr
      store_wall_geom(wall, length: length, thickness: thickness, height: height, align: pr[:align], ext: ext,
                            auto: auto.nil? ? g[:auto] : auto, type_id: type && type['id'], flipped: flipped)
      wall.set_attribute(BimData::DICT, 'openings', JSON.generate(openings)) unless openings.empty?
      true
    end

    # Estremità di un muro parametrico del contesto attivo vicina al punto
    # (in pianta, stessa quota di base). Restituisce { wall:, at: :p1|:p2, point:, params: }.
    def wall_end_near(model, point, tolerance, exclude = nil)
      wall_ends_near(model, point, tolerance, exclude).first
    end

    # Tutte le estremità di muri entro tolerance dal punto, dalla più vicina.
    def wall_ends_near(model, point, tolerance, exclude = nil)
      hits = []
      model.active_entities.each do |e|
        next if e == exclude || !parametric_wall?(e)

        pr = wall_params(model, e)
        next if pr.nil? || (pr[:p1].z - point.z).abs > 1.mm

        { p1: pr[:p1], p2: pr[:p2] }.each do |at, q|
          d = Math.hypot(q.x - point.x, q.y - point.y)
          hits << [d, { wall: e, at: at, point: q, params: pr }] if d <= tolerance
        end
      end
      hits.sort_by(&:first).map(&:last)
    end

    # Raggio entro cui un nuovo muro si aggancia all'estremità di un muro esistente.
    def snap_tolerance(thickness)
      thickness * 1.5
    end

    # Raccorda a quartabuono due muri che si incontrano: "arriving" ha
    # l'estremità arr_end nell'angolo, "leaving" l'estremità lea_end (un muro
    # che parte dall'angolo con :p2 viene considerato percorso al contrario).
    # Adatta entrambi i muri, oppure nessuno se uno dei due non si può adattare.
    def join_ends(model, arriving, arr_end, leaving, lea_end)
      pa = wall_params(model, arriving)
      pl = wall_params(model, leaving)
      return false unless pa && pl

      a_fwd = arr_end == :p2
      l_fwd = lea_end == :p1
      dir_a = a_fwd ? planar_dir(pa[:p1], pa[:p2]) : planar_dir(pa[:p2], pa[:p1])
      dir_l = l_fwd ? planar_dir(pl[:p1], pl[:p2]) : planar_dir(pl[:p2], pl[:p1])
      band_a = WallJoint.band(pa[:align], pa[:thickness].to_f)
      band_a = WallJoint.flip(band_a) unless a_fwd
      band_l = WallJoint.band(pl[:align], pl[:thickness].to_f)
      band_l = WallJoint.flip(band_l) unless l_fwd
      ends_a, starts_l = WallJoint.corner(dir_a, dir_l, band_a, band_l) || [[0.0, 0.0], [0.0, 0.0]]

      ext_a = a_fwd ? pa[:ext].dup : WallJoint.flip_ext(pa[:ext])
      ext_a[2], ext_a[3] = ends_a
      ext_a = WallJoint.flip_ext(ext_a) unless a_fwd
      ext_l = l_fwd ? pl[:ext].dup : WallJoint.flip_ext(pl[:ext])
      ext_l[0], ext_l[1] = starts_l
      ext_l = WallJoint.flip_ext(ext_l) unless l_fwd

      return false unless reshape_wall(model, arriving, ext_a, dry_run: true) &&
                          reshape_wall(model, leaving, ext_l, dry_run: true)

      reshape_wall(model, arriving, ext_a) && reshape_wall(model, leaving, ext_l)
    end

    # Ricalcola i giunti alle due estremità di un muro (es. dopo un cambio di
    # spessore): un'estremità che coincide con quella di un solo altro muro
    # viene raccordata, un'estremità libera torna a testata dritta.
    def rejoin_wall(model, wall)
      %i[p1 p2].each do |at|
        pr = wall_params(model, wall)
        next unless pr

        others = wall_ends_near(model, pr[at], 1.mm, wall)
        if others.size == 1
          o = others.first
          if at == :p2
            join_ends(model, wall, :p2, o[:wall], o[:at])
          else
            join_ends(model, o[:wall], o[:at], wall, :p1)
          end
        elsif others.empty?
          ext = pr[:ext].dup
          if at == :p1
            ext[0] = ext[1] = 0.0
          else
            ext[2] = ext[3] = 0.0
          end
          reshape_wall(model, wall, ext)
        end
      end
    end

    # Muro da p1 a p2 che si aggancia ai muri esistenti: se un estremo cade
    # vicino all'estremità di un altro muro parametrico, il punto viene
    # portato sull'asse di quel muro e l'angolo viene raccordato a quartabuono
    # (anche il muro esistente viene adattato). Restituisce
    # { wall:, end_point:, joined_end: }.
    def wall_connected(model, p1, p2, thickness, height, align = 'center', auto_height: true,
                       type_id: nil, flipped: false)
      type = WallTypeLibrary.find(model, type_id)
      thickness = WallTypes.thickness(type).m if type
      tol = snap_tolerance(thickness)
      start_hit = wall_end_near(model, p1, tol)
      p1 = start_hit[:point] if start_hit
      end_hit = wall_end_near(model, p2, tol, start_hit && start_hit[:wall])
      p2 = Geom::Point3d.new(end_hit[:point].x, end_hit[:point].y, p1.z) if end_hit
      return nil if Math.hypot(p2.x - p1.x, p2.y - p1.y) < Geometry::TOL

      group = wall(model, p1, p2, thickness, height, align, auto_height: auto_height,
                                                            type_id: type && type['id'], flipped: flipped)
      return nil unless group

      join_ends(model, start_hit[:wall], start_hit[:at], group, :p1) if start_hit
      join_ends(model, group, :p2, end_hit[:wall], end_hit[:at]) if end_hit
      { wall: group, end_point: p2, joined_end: !end_hit.nil? }
    end

    def planar_dir(p, q)
      WallJoint.direction([p.x.to_f, p.y.to_f], [q.x.to_f, q.y.to_f])
    end

    # Sequenza di muri tra i punti indicati (stessa quota), con i giunti
    # d'angolo calcolati da WallJoint. Se closed, l'ultimo punto si ricollega
    # al primo. Restituisce i gruppi creati.
    def wall_chain(model, points, thickness, height, align = 'center', closed: false, auto_height: true,
                   type_id: nil, flipped: false)
      type = WallTypeLibrary.find(model, type_id)
      thickness = WallTypes.thickness(type).m if type
      lo, hi = WallJoint.band(align, thickness.to_f)
      exts = WallJoint.chain(points.map { |p| [p.x.to_f, p.y.to_f] }, lo, hi, closed: closed)
      ends = points.each_cons(2).to_a
      ends << [points.last, points.first] if closed && points.size > 2
      ends.each_with_index.map do |(p1, p2), i|
        wall(model, p1, p2, thickness, height, align, ext: exts[i], auto_height: auto_height,
                                                      type_id: type && type['id'], flipped: flipped)
      end
    end

    # Assegna (o toglie, con type_id nil) una tipologia a un muro: lo spessore
    # diventa quello della stratigrafia, gli strati vengono costruiti e i
    # giunti con i muri adiacenti ricalcolati.
    def apply_wall_type(model, wall, type_id, flipped: nil)
      pr = wall_params(model, wall)
      return false unless pr && reshape_wall(model, wall, pr[:ext], type_id: type_id, flipped: flipped)

      rejoin_wall(model, wall)
      type = wall_type(model, wall)
      apply_type_data(model, wall, type) if type
      true
    end

    # Aggiorna tutti i muri del contesto attivo che usano la tipologia (dopo
    # una modifica della libreria). Restituisce il numero di muri non adattati.
    def update_type_walls(model, type_id, remove: false)
      walls = model.active_entities.select do |e|
        parametric_wall?(e) && (g = wall_geom(e)) && g[:type_id] == type_id
      end
      walls.count { |w| !apply_wall_type(model, w, remove ? nil : type_id) }
    end

    # Dati derivati dalla tipologia: tipologia (ObjectType) e trasmittanza U.
    def apply_type_data(_model, wall, type)
      props = BimData.json_attr(wall, 'props')
      u = WallTypes.u_value(type, external: props['IsExternal'] == true)
      props['ThermalTransmittance'] = u.round(4) if u
      wall.set_attribute(BimData::DICT, 'props', JSON.generate(props))
      wall.set_attribute(BimData::DICT, 'object_type', type['name'])
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
    def column(model, center, width, depth, height, rotation = 0.0, auto_height: true)
      xaxis = Geom::Vector3d.new(Math.cos(rotation), Math.sin(rotation), 0)
      tr0 = Geometry.frame_transform(center, xaxis)
      origin = Geom::Point3d.new(-width / 2.0, -depth / 2.0, 0).transform(tr0)
      tr = Geometry.frame_transform(origin, xaxis)
      group = Geometry.create_group(model, tr) { |ents| Geometry.box(ents, width, depth, height) }
      finish(model, group, 'column')
      group.set_attribute(BimData::DICT, 'auto_height', auto_height ? true : false)
      group
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
      finish(model, group, 'beam', { 'auto_top' => true })
    end

    # Altezza di muri e pilastri parametrici: { height: (mondo), auto: } o nil.
    def element_height(model, entity)
      return nil unless BimData.element?(entity) && entity.get_attribute(BimData::DICT, 'parametric') == true

      case BimData.type_key(entity)
      when 'wall'
        g = wall_geom(entity)
        g && { height: g[:height] * Geometry.scales(entity.transformation)[2], auto: g[:auto] }
      when 'column'
        bb = entity.definition.bounds
        auto = entity.get_attribute(BimData::DICT, 'auto_height')
        { height: (bb.max.z - bb.min.z) * Geometry.scales(entity.transformation)[2], auto: auto != false }
      end
    end

    # Imposta l'altezza di un muro o pilastro parametrico. Con auto: true
    # l'altezza diventa (e resta) quella del livello dell'elemento.
    # Restituisce false se l'elemento non può essere ricostruito.
    def set_height(model, entity, height: nil, auto: false)
      info = element_height(model, entity)
      return false unless info

      if auto
        lvl = Levels.find(model, BimData.level_id(entity)) || Levels.for_entity(model, entity)
        height = lvl['height'].m
      end
      return false unless height && height.to_f >= 0.1.m

      case BimData.type_key(entity)
      when 'wall'
        pr = wall_params(model, entity)
        pr ? reshape_wall(model, entity, pr[:ext], height: height, auto: auto) : false
      when 'column'
        resize_column(entity, height, auto)
      else
        false
      end
    end

    def resize_column(column, height, auto)
      bb = column.definition.bounds
      sx, sy, sz = Geometry.scales(column.transformation)
      w = (bb.max.x - bb.min.x) * sx
      d = (bb.max.y - bb.min.y) * sy
      expected = (bb.max.x - bb.min.x) * (bb.max.y - bb.min.y) * (bb.max.z - bb.min.z) * sx * sy * sz
      return false unless column.volume > 0 && (column.volume - expected).abs <= [expected * 0.001, 1.0].max

      tr = column.transformation
      origin = Geom::Point3d.new(bb.min.x, bb.min.y, bb.min.z).transform(tr)
      xaxis = X_AXIS.transform(tr)
      column.make_unique if column.respond_to?(:make_unique)
      column.definition.entities.clear!
      Geometry.box(column.definition.entities, w, d, height)
      column.transformation = Geometry.frame_transform(origin, xaxis)
      column.set_attribute(BimData::DICT, 'auto_height', auto ? true : false)
      true
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

    # Il muro corrisponde ancora ai suoi parametri (impronta per altezza meno
    # le aperture)? Se è stato modificato a mano la ricostruzione ne
    # perderebbe le modifiche.
    def wall_intact?(wall)
      g = wall_geom(wall)
      det = Geometry.scales(wall.transformation).reduce(:*)
      vol = Geometry.solid_volume(wall)
      return false unless g && vol > 0 && det > 0

      base = WallJoint.area(WallJoint.footprint(g[:length], g[:thickness], g[:ext])) * g[:height]
      expected = base - wall_openings(wall).sum { |a, b, c, d| (b - a) * (d - c) * g[:thickness] }
      (vol / det - expected).abs <= [expected * 0.001, 1.0].max
    end

    # Calcola il rettangolo dell'apertura (coordinate locali del muro).
    # Restituisce [a, b, c, d] oppure nil se non entra nel muro o si
    # sovrappone a un'altra apertura.
    def opening_rect(wall, local_x, width, height, sill)
      sx, _sy, sz = Geometry.scales(wall.transformation)
      g = wall_geom(wall)
      return nil unless g

      x0, x1 = WallJoint.core_range(g[:length], g[:ext])
      z0 = 0.0
      z_top = g[:height]
      w = width.to_f / sx
      h = height.to_f / sz
      c = z0 + sill.to_f / sz
      local_x = local_x.to_f
      gap = OPENING_GAP / sx
      door = sill <= Geometry::TOL
      margin = door ? 0 : gap
      if WallJoint.normalize_ext(g[:ext]).any? { |e| e.abs > Geometry::TOL }
        x0 += gap
        x1 -= gap
      end
      return nil if w > (x1 - x0) - 2 * margin || c + h > z_top - OPENING_GAP / sz

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
      g = wall_geom(wall)
      type = WallTypeLibrary.find(model, g[:type_id])
      layers = type ? WallTypeLibrary.geometry_layers(model, type, g[:thickness], g[:flipped]) : nil
      wall.make_unique if wall.respond_to?(:make_unique)
      wall.definition.entities.clear!
      Geometry.build_wall(wall.definition.entities, g[:length], g[:thickness], g[:height], g[:ext], openings,
                          layers: layers)
      store_wall_geom(wall, g)
      wall.set_attribute(BimData::DICT, 'openings', JSON.generate(openings))
      wall_tr = wall.transformation
      t = g[:thickness]
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
