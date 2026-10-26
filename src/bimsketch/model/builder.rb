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

    # Giunto a T: muro parametrico (diverso da exclude) sul cui corpo cade il
    # punto, lontano dalle sue estremità. extra allarga la fascia del muro.
    # Restituisce { wall:, point: (proiezione sull'asse), params: } o nil.
    def wall_side_near(model, point, extra, exclude = nil, on_axis: false)
      best = nil
      model.active_entities.each do |e|
        next if e == exclude || !parametric_wall?(e)

        pr = wall_params(model, e)
        next if pr.nil? || (pr[:p1].z - point.z).abs > 1.mm

        a = [pr[:p1].x.to_f, pr[:p1].y.to_f]
        b = [pr[:p2].x.to_f, pr[:p2].y.to_f]
        dist, t, q, len = WallJoint.project([point.x.to_f, point.y.to_f], a, b)
        next unless t > Geometry::TOL && t < len - Geometry::TOL

        d = WallJoint.direction(a, b)
        offset = (point.x - q[0]) * -d[1] + (point.y - q[1]) * d[0]
        lo, hi = WallJoint.band(pr[:align], pr[:thickness].to_f)
        inside = on_axis ? dist < 1.mm : offset >= lo - extra && offset <= hi + extra
        next unless inside

        best = [dist, { wall: e, point: Geom::Point3d.new(q[0], q[1], point.z), params: pr }] if best.nil? || dist < best[0]
      end
      best && best[1]
    end

    # Taglia l'estremità "at" del muro sulla faccia del muro ospite il cui asse
    # passa per quell'estremità (giunto a T). Il muro ospite non cambia.
    # Restituisce true se il giunto è stato applicato.
    def apply_tee(model, wall, at)
      pr = wall_params(model, wall)
      return false unless pr

      host = wall_side_near(model, pr[at], 0, wall, on_axis: true)
      return false unless host

      hp = host[:params]
      h1 = [hp[:p1].x.to_f, hp[:p1].y.to_f]
      d_h = planar_dir(hp[:p1], hp[:p2])
      band_h = WallJoint.band(hp[:align], hp[:thickness].to_f)
      other = at == :p1 ? pr[:p2] : pr[:p1]
      face = WallJoint.facing_offset(h1, d_h, band_h, [other.x.to_f, other.y.to_f])
      point = [pr[at].x.to_f, pr[at].y.to_f]
      s = WallJoint.tee(point, planar_dir(pr[:p1], pr[:p2]), WallJoint.band(pr[:align], pr[:thickness].to_f),
                        h1, d_h, face)
      return false unless s

      ext = pr[:ext].dup
      if at == :p1
        ext[0] = -s[0]
        ext[1] = -s[1]
      else
        ext[2] = s[0]
        ext[3] = s[1]
      end
      reshape_wall(model, wall, ext)
    end

    # Ricalcola i giunti a T dei muri che terminano sul muro ospite (dopo un
    # cambio del suo spessore).
    def retee_attached(model, host)
      hp = wall_params(model, host)
      return unless hp

      model.active_entities.to_a.each do |e|
        next if e == host || !parametric_wall?(e)

        pr = wall_params(model, e)
        next unless pr

        %i[p1 p2].each do |at|
          h = wall_side_near(model, pr[at], 0, e, on_axis: true)
          apply_tee(model, e, at) if h && h[:wall] == host
        end
      end
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
          next if apply_tee(model, wall, at)

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
    # (anche il muro esistente viene adattato); se cade sul corpo di un muro,
    # il nuovo muro si ferma sulla sua faccia (giunto a T). Restituisce
    # { wall:, end_point:, joined_end: }.
    def wall_connected(model, p1, p2, thickness, height, align = 'center', auto_height: true,
                       type_id: nil, flipped: false)
      type = WallTypeLibrary.find(model, type_id)
      thickness = WallTypes.thickness(type).m if type
      tol = snap_tolerance(thickness)
      start_hit = wall_end_near(model, p1, tol)
      p1 = start_hit[:point] if start_hit
      start_tee = start_hit ? nil : wall_side_near(model, p1, thickness)
      p1 = start_tee[:point] if start_tee
      end_hit = wall_end_near(model, p2, tol, start_hit && start_hit[:wall])
      p2 = Geom::Point3d.new(end_hit[:point].x, end_hit[:point].y, p1.z) if end_hit
      end_tee = end_hit ? nil : wall_side_near(model, p2, thickness, start_tee && start_tee[:wall])
      p2 = Geom::Point3d.new(end_tee[:point].x, end_tee[:point].y, p1.z) if end_tee
      return nil if Math.hypot(p2.x - p1.x, p2.y - p1.y) < Geometry::TOL

      group = wall(model, p1, p2, thickness, height, align, auto_height: auto_height,
                                                            type_id: type && type['id'], flipped: flipped)
      return nil unless group

      join_ends(model, start_hit[:wall], start_hit[:at], group, :p1) if start_hit
      join_ends(model, group, :p2, end_hit[:wall], end_hit[:at]) if end_hit
      apply_tee(model, group, :p1) if start_tee
      apply_tee(model, group, :p2) if end_tee
      { wall: group, end_point: p2, joined_end: !(end_hit || end_tee).nil? }
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
      retee_attached(model, wall)
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

    # Tipi di elemento a cui si può assegnare una tipologia di solaio.
    SLAB_TYPES = %w[slab roof].freeze

    # Solaio da un poligono (punti mondo); la faccia superiore sta alla quota
    # top_z. type_id: tipologia di solaio con stratigrafia (lo spessore
    # diventa quello della tipologia).
    def slab(model, points, thickness, top_z, holes: [], type_key: 'slab', type_id: nil)
      type = WallTypeLibrary.find(model, type_id, kind: 'slab')
      thickness = WallTypes.thickness(type).m if type
      return nil if points.size < 3

      base_z = top_z - thickness
      min_x = points.map(&:x).min
      min_y = points.map(&:y).min
      flat = ->(poly) { poly.map { |p| [(p.x - min_x).to_f, (p.y - min_y).to_f] } }
      outline = flat.call(points)
      local_holes = holes.map { |h| flat.call(h) }
      tr = Geom::Transformation.translation(Geom::Point3d.new(min_x, min_y, base_z))
      layers = type ? WallTypeLibrary.slab_layers(model, type, thickness) : nil
      group = Geometry.create_group(model, tr) do |ents|
        Geometry.build_slab(ents, outline, local_holes, 0.0, thickness, layers: layers)
      end
      finish(model, group, type_key)
      store_slab_geom(group, outline: outline, holes: local_holes, base: 0.0, thickness: thickness.to_f,
                             type_id: type && type['id'])
      apply_slab_type_data(model, group, type) if type
      group
    end

    def store_slab_geom(slab, g)
      geom = { 'outline' => g[:outline], 'holes' => g[:holes], 'base' => g[:base].to_f,
               'thickness' => g[:thickness].to_f, 'type_id' => g[:type_id] }
      slab.set_attribute(BimData::DICT, 'slab_geom', JSON.generate(geom))
    end

    # Parametri del solaio nel suo sistema locale (unità interne, senza scala):
    # { outline:, holes:, base:, thickness:, type_id: }. Per i solai senza
    # 'slab_geom' (versioni precedenti, elementi da faccia) il contorno viene
    # letto dalla faccia superiore; nil se l'elemento non è un prisma semplice.
    def slab_geom(slab)
      raw = slab.get_attribute(BimData::DICT, 'slab_geom')
      if raw
        g = JSON.parse(raw)
        return { outline: g['outline'], holes: g['holes'] || [], base: g['base'].to_f,
                 thickness: g['thickness'].to_f, type_id: g['type_id'] }
      end
      ents = slab.definition.entities
      bb = slab.definition.bounds
      top = ents.grep(Sketchup::Face).select do |f|
        f.normal.z > 0.999 && (f.vertices.first.position.z - bb.max.z).abs < 0.01.mm
      end.max_by(&:area)
      return nil unless top

      loop_xy = ->(lp) { lp.vertices.map { |v| [v.position.x.to_f, v.position.y.to_f] } }
      { outline: loop_xy.call(top.outer_loop), holes: top.loops.reject(&:outer?).map { |l| loop_xy.call(l) },
        base: bb.min.z.to_f, thickness: (bb.max.z - bb.min.z).to_f, type_id: nil }
    rescue JSON::ParserError
      nil
    end

    # Solaio o copertura di cui si può ricostruire la geometria (prisma).
    def parametric_slab?(entity)
      BimData.element?(entity) && SLAB_TYPES.include?(BimData.type_key(entity)) && !slab_geom(entity).nil?
    end

    # Tipologia di solaio assegnata all'elemento, o nil.
    def slab_type(model, slab)
      WallTypeLibrary.find(model, slab_geom_type_id(slab), kind: 'slab')
    end

    # Il solaio corrisponde ancora al suo contorno per lo spessore?
    def slab_intact?(slab, g = slab_geom(slab))
      det = Geometry.scales(slab.transformation).reduce(:*)
      vol = Geometry.solid_volume(slab)
      return false unless g && vol > 0 && det > 0

      area = WallJoint.area(g[:outline]) - g[:holes].sum { |h| WallJoint.area(h) }
      expected = area * g[:thickness]
      (vol / det - expected).abs <= [expected * 0.001, 1.0].max
    end

    # Assegna (o toglie, con type_id nil) una tipologia a un solaio: la faccia
    # superiore resta alla sua quota, lo spessore diventa quello della
    # stratigrafia e gli strati vengono costruiti. Rifiuta i solai modificati a mano.
    def apply_slab_type(model, slab, type_id)
      g = slab_geom(slab)
      return false unless g && slab_intact?(slab, g)

      type = WallTypeLibrary.find(model, type_id, kind: 'slab')
      sz = Geometry.scales(slab.transformation)[2]
      top = g[:base] + g[:thickness]
      thickness = type ? WallTypes.thickness(type).m / sz : g[:thickness]
      base = top - thickness
      slab.make_unique if slab.respond_to?(:make_unique)
      ents = slab.definition.entities
      ents.clear!
      layers = type ? WallTypeLibrary.slab_layers(model, type, thickness) : nil
      Geometry.build_slab(ents, g[:outline], g[:holes], base, thickness, layers: layers)
      store_slab_geom(slab, outline: g[:outline], holes: g[:holes], base: base, thickness: thickness,
                            type_id: type && type['id'])
      apply_slab_type_data(model, slab, type) if type
      true
    end

    # Aggiorna i solai del contesto attivo che usano la tipologia.
    # Restituisce il numero di solai non adattati.
    def update_type_slabs(model, type_id, remove: false)
      slabs = model.active_entities.select { |e| (t = slab_geom_type_id(e)) && t == type_id }
      slabs.count { |s| !apply_slab_type(model, s, remove ? nil : type_id) }
    end

    def slab_geom_type_id(entity)
      return nil unless BimData.element?(entity) && SLAB_TYPES.include?(BimData.type_key(entity))

      raw = entity.get_attribute(BimData::DICT, 'slab_geom')
      raw && JSON.parse(raw)['type_id']
    rescue JSON::ParserError
      nil
    end

    # Dati derivati dalla tipologia di solaio: ObjectType e trasmittanza U
    # (flusso verso il basso per i solai, verso l'alto per le coperture).
    def apply_slab_type_data(_model, slab, type)
      props = BimData.json_attr(slab, 'props')
      u = WallTypes.u_value(type, external: props['IsExternal'] == true,
                                  flow: WallTypes.flow_for(BimData.type_key(slab)))
      props['ThermalTransmittance'] = u.round(4) if u
      slab.set_attribute(BimData::DICT, 'props', JSON.generate(props))
      slab.set_attribute(BimData::DICT, 'object_type', type['name'])
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
    # ignore: rettangolo di un'apertura esistente da non considerare (quando
    # la si sostituisce).
    def opening_rect(wall, local_x, width, height, sill, ignore: nil)
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
      others = wall_openings(wall)
      others = others.reject { |r| same_rect?(r, ignore) } if ignore
      return nil if WallProfile.overlaps?(rect, others, gap)

      rect
    end

    def same_rect?(r, q)
      r.zip(q).all? { |u, v| (u - v).abs < 0.5.mm }
    end

    # Inserisce una porta o una finestra in un muro parametrico: taglia il
    # foro nel muro e crea l'elemento nel vano. type_id: tipologia
    # (OpeningTypes) che ne stabilisce la forma; nil = quella predefinita.
    def opening(model, wall, kind, local_x, width, height, sill, type_id: nil)
      rect = opening_rect(wall, local_x, width, height, sill)
      return nil unless rect

      raise "il muro è stato modificato a mano: non è possibile inserire l'apertura" unless wall_intact?(wall)

      rebuild_wall_openings(model, wall, wall_openings(wall) + [rect])
      group = place_opening(model, nil, wall, kind, rect, OpeningTypes.for_kind(kind, type_id))
      finish(model, group, kind, { 'host' => BimData.guid(wall) }, level: BimData.level_id(wall))
      external = BimData.json_attr(wall, 'props')['IsExternal']
      unless external.nil?
        props = BimData.json_attr(group, 'props').merge('IsExternal' => external)
        group.set_attribute(BimData::DICT, 'props', JSON.generate(props))
      end
      group
    end

    # Ricostruisce il muro con le aperture indicate (coordinate locali).
    def rebuild_wall_openings(model, wall, openings)
      g = wall_geom(wall)
      type = WallTypeLibrary.find(model, g[:type_id])
      layers = type ? WallTypeLibrary.geometry_layers(model, type, g[:thickness], g[:flipped]) : nil
      wall.make_unique if wall.respond_to?(:make_unique)
      wall.definition.entities.clear!
      Geometry.build_wall(wall.definition.entities, g[:length], g[:thickness], g[:height], g[:ext], openings,
                          layers: layers)
      store_wall_geom(wall, g)
      wall.set_attribute(BimData::DICT, 'openings', JSON.generate(openings))
    end

    # Trasformazione (coordinate del contesto del muro) e profondità della
    # porta o finestra nel vano rect del muro.
    def opening_frame(wall, kind, rect)
      a, _b, c, _d = rect
      wall_tr = wall.transformation
      t = wall_geom(wall)[:thickness]
      sy = Geometry.scales(wall_tr)[1]
      depth = [kind == 'door' ? 100.mm : 80.mm, t * sy].min
      origin = Geom::Point3d.new(a, t / 2.0, c).transform(wall_tr)
      xaxis = X_AXIS.transform(wall_tr)
      [Geometry.frame_transform(origin.offset(Z_AXIS * xaxis.normalize, -depth / 2.0), xaxis), depth]
    end

    # Costruisce la porta o finestra nel vano rect del muro: in un nuovo
    # gruppo, oppure (group) sostituendo la geometria di un'apertura esistente.
    def place_opening(model, group, wall, kind, rect, type)
      a, b, c, d = rect
      sx, _sy, sz = Geometry.scales(wall.transformation)
      tr, depth = opening_frame(wall, kind, rect)
      w = (b - a) * sx
      h = (d - c) * sz
      build = lambda do |ents|
        kind == 'door' ? build_door(model, ents, type, w, depth, h) : build_window(model, ents, type, w, depth, h)
      end
      if group
        group.make_unique if group.respond_to?(:make_unique)
        group.definition.entities.clear!
        build.call(group.definition.entities)
        group.transformation = tr
      else
        group = Geometry.create_group(model, model.active_path ? model.edit_transform * tr : tr, &build)
      end
      group.set_attribute(BimData::DICT, 'opening_type', type['id'])
      group.set_attribute(BimData::DICT, 'operation', type['operation'])
      group.set_attribute(BimData::DICT, 'object_type', type['name'])
      store_placement(group, rect)
      group
    end

    # Registra il vano occupato nel muro e la posizione dell'apertura:
    # OpeningSync li confronta per riconoscere gli spostamenti fatti con gli
    # strumenti di SketchUp.
    def store_placement(opening, rect)
      opening.set_attribute(BimData::DICT, 'wall_rect', JSON.generate(rect.map(&:to_f)))
      opening.set_attribute(BimData::DICT, 'placed_tr', JSON.generate(opening.transformation.to_a))
    end

    # Muro parametrico (nel contesto attivo) che ospita l'apertura.
    def host_wall(model, opening)
      host = opening.get_attribute(BimData::DICT, 'host')
      return nil if host.to_s.empty?

      walls = model.active_entities.select { |e| parametric_wall?(e) && BimData.guid(e) == host }
      return walls.first if walls.size < 2

      # Muri con lo stesso GlobalId (copiati insieme alle aperture): quello in
      # cui l'apertura è al suo posto, altrimenti il più vicino.
      walls.find { |w| opening_in_place?(w, opening) } ||
        walls.min_by { |w| w.bounds.center.distance(opening.bounds.center) }
    end

    # Vano del muro occupato dall'apertura: il rettangolo registrato nel muro
    # che coincide con l'ingombro dell'apertura (coordinate locali del muro).
    def opening_rect_of(wall, opening)
      stored = stored_rect(opening)
      if stored && opening_in_place?(wall, opening)
        found = wall_openings(wall).find { |r| same_rect?(r, stored) }
        return found if found
      end
      inv = wall.transformation.inverse
      pts = (0..7).map { |i| opening.bounds.corner(i).transform(inv) }
      box = [pts.map(&:x).min, pts.map(&:x).max, pts.map(&:z).min, pts.map(&:z).max].map(&:to_f)
      best = wall_openings(wall).min_by { |r| r.zip(box).sum { |u, v| (u - v).abs } }
      best && best.zip(box).all? { |u, v| (u - v).abs < 5.mm } ? best : nil
    end

    def stored_rect(opening)
      raw = opening.get_attribute(BimData::DICT, 'wall_rect')
      raw && JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    # L'apertura è ancora dove l'ha messa BIMSketch rispetto al suo muro?
    def opening_in_place?(wall, opening)
      rect = stored_rect(opening)
      return false unless rect

      tr, = opening_frame(wall, BimData.type_key(opening), rect)
      same_transform?(tr, opening.transformation)
    end

    def same_transform?(t1, t2)
      t1.to_a.zip(t2.to_a).all? { |u, v| (u - v).abs < 1e-4 }
    end

    # Cambia la tipologia di una porta o finestra: prende le dimensioni della
    # nuova tipologia (stesso centro nel muro), il foro nel muro viene
    # ritagliato e l'apertura ricostruita mantenendo GlobalId e proprietà.
    # false se l'apertura non entra o il muro non è ricostruibile.
    def change_opening_type(model, opening, type_id)
      kind = BimData.type_key(opening)
      return false unless %w[door window].include?(kind)

      wall = host_wall(model, opening)
      return false unless wall && wall_intact?(wall)

      old = opening_rect_of(wall, opening)
      return false unless old

      type = OpeningTypes.for_kind(kind, type_id)
      rect = opening_rect(wall, (old[0] + old[1]) / 2.0, type['width'].m, type['height'].m, type['sill'].m,
                          ignore: old)
      return false unless rect

      rebuild_wall_openings(model, wall, wall_openings(wall).map { |r| same_rect?(r, old) ? rect : r })
      place_opening(model, opening, wall, kind, rect, type)
      true
    end

    # Posizione di una porta o finestra nel suo muro (unità interne, mondo):
    # { left: distanza del lato sinistro del vano dall'inizio del muro,
    #   sill: quota del vano dalla base del muro, width:, height:, wall: } o nil.
    def opening_position(model, opening)
      wall = host_wall(model, opening)
      rect = wall && opening_rect_of(wall, opening)
      return nil unless rect

      sx, _sy, sz = Geometry.scales(wall.transformation)
      { left: rect[0] * sx, sill: rect[2] * sz, width: (rect[1] - rect[0]) * sx,
        height: (rect[3] - rect[2]) * sz, wall: wall, rect: rect }
    end

    # Sposta una porta o finestra nel suo muro: left = distanza del lato
    # sinistro del vano dall'inizio del muro, sill = davanzale (solo
    # finestre); nil lascia il valore attuale. Il foro viene ritagliato nella
    # nuova posizione. Con strict una posizione fuori dal muro viene
    # rifiutata, altrimenti l'apertura si ferma al limite del muro.
    # Restituisce false se l'apertura non entra o si sovrappone a un'altra.
    def move_opening(model, opening, left: nil, sill: nil, strict: true)
      kind = BimData.type_key(opening)
      pos = %w[door window].include?(kind) && opening_position(model, opening)
      return false unless pos && wall_intact?(pos[:wall])

      wall = pos[:wall]
      old = pos[:rect]
      sx = Geometry.scales(wall.transformation)[0]
      left = (left || pos[:left]).to_f
      sill = kind == 'door' ? 0 : (sill || pos[:sill]).to_f
      center = left / sx + (old[1] - old[0]) / 2.0
      rect = opening_rect(wall, center, pos[:width], pos[:height], sill, ignore: old)
      return false unless rect
      return false if strict && (rect[0] * sx - left).abs > 0.5.mm
      return true if same_rect?(rect, old)

      rebuild_wall_openings(model, wall, wall_openings(wall).map { |r| same_rect?(r, old) ? rect : r })
      type = OpeningTypes.for_kind(kind, opening.get_attribute(BimData::DICT, 'opening_type'))
      place_opening(model, opening, wall, kind, rect, type)
      true
    end

    # Porta: telaio a U (senza traverso a terra) e ante piene, scorrevoli o vetrate.
    def build_door(model, ents, type, width, depth, height)
      glazed = type['style'] == 'glazed'
      f = [60.mm, width / 6.0].min
      frame_mat = glazed ? part_material(model, 'BIM Telaio serramento', [238, 238, 232]) :
                           part_material(model, 'BIM Telaio porta', [115, 80, 50])
      Geometry.part(ents, 'Telaio', frame_mat) do |e|
        Geometry.extrude_xz(e, [[0, 0], [f, 0], [f, height - f], [width - f, height - f], [width - f, 0],
                                [width, 0], [width, height], [0, height]], depth)
      end
      z0 = 10.mm
      lh = height - f - 3.mm - z0
      lt = [45.mm, depth * 0.8].min
      y = type['style'] == 'sliding' ? 0 : (depth - lt) / 2.0
      OpeningTypes.leaf_spans(width - 2 * f - 6.mm, type['leaves'], 4.mm).each do |x0, x1|
        x = f + 3.mm + x0
        if glazed
          sash(model, ents, x, y, z0, x1 - x0, lt, lh, 70.mm, frame_mat)
        else
          Geometry.part(ents, 'Anta', part_material(model, 'BIM Anta porta', [175, 125, 80]), [x, y, z0]) do |e|
            Geometry.box(e, x1 - x0, lt, lh)
          end
        end
      end
    end

    # Finestra: telaio fisso con ante vetrate (o vetro fisso).
    def build_window(model, ents, type, width, depth, height)
      f = [60.mm, width / 6.0, height / 6.0].min
      frame_mat = part_material(model, 'BIM Telaio serramento', [238, 238, 232])
      Geometry.part(ents, 'Telaio', frame_mat) { |e| Geometry.frame(e, width, height, f, depth) }
      if type['style'] == 'fixed' || type['leaves'].to_i < 1
        glass_pane(model, ents, f, depth / 2.0, f, width - 2 * f, height - 2 * f)
        return
      end
      st = depth * 0.75
      y = (depth - st) / 2.0
      OpeningTypes.leaf_spans(width - 2 * f, type['leaves'], 2.mm).each do |x0, x1|
        sash(model, ents, f + x0, y, f, x1 - x0, st, height - 2 * f, 50.mm, frame_mat)
      end
    end

    # Anta vetrata: telaio dell'anta (profilo p, spessore t) e vetro al centro.
    def sash(model, ents, x, y, z, width, t, height, p, material)
      p = [p, width / 4.0, height / 4.0].min
      Geometry.part(ents, 'Anta', material, [x, y, z]) { |e| Geometry.frame(e, width, height, p, t) }
      glass_pane(model, ents, x + p, y + t / 2.0, z + p, width - 2 * p, height - 2 * p)
    end

    # Vetro di 8 mm centrato in y = y_mid.
    def glass_pane(model, ents, x, y_mid, z, width, height)
      g = 8.mm
      Geometry.part(ents, 'Vetro', glass_material(model), [x, y_mid - g / 2.0, z]) do |e|
        Geometry.box(e, width, g, height)
      end
    end

    def part_material(model, name, rgb)
      model.materials[name] || model.materials.add(name).tap { |m| m.color = Sketchup::Color.new(*rgb) }
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
