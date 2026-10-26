# frozen_string_literal: true

module BIMSketch
  # Raccoglie gli elementi BIM del modello SketchUp e ne calcola misure,
  # mesh e dati in forma di "record" (vedi Records).
  module Collector
    IN_TO_M = 0.0254
    IN2_TO_M2 = IN_TO_M**2
    IN3_TO_M3 = IN_TO_M**3
    AXIS_TOL = 0.999
    VERTICAL_TOL = 0.001

    module_function

    # Opzioni:
    #   mesh:    true per includere la geometria triangolata
    #   proxies: true per includere i gruppi/componenti non classificati
    #            (come IfcBuildingElementProxy)
    def collect(model, mesh: false, proxies: false)
      out = []
      @contains_cache = {}
      walk(model, model.entities, Geom::Transformation.new, mesh, proxies, out)
      out
    end

    # Tutte le entità BIM con la relativa trasformazione mondo (anche annidate).
    def each_element(model, &block)
      @contains_cache = {}
      visit(model.entities, Geom::Transformation.new, &block)
    end

    def visit(ents, tr, &block)
      ents.each do |e|
        next unless BimData.instance?(e)

        world = tr * e.transformation
        if BimData.element?(e)
          yield e, world
        elsif contains_bim?(e.definition)
          visit(e.definition.entities, world, &block)
        end
      end
    end

    def find_by_guid(model, guid)
      each_element(model) { |e, _| return e if BimData.guid(e) == guid }
      nil
    end

    def walk(model, ents, tr, mesh, proxies, out)
      ents.each do |e|
        next unless BimData.instance?(e)

        world = tr * e.transformation
        if BimData.element?(e)
          out << record(model, e, world, mesh)
        elsif contains_bim?(e.definition)
          walk(model, e.definition.entities, world, mesh, proxies, out)
        elsif proxies
          out << record(model, e, world, mesh, proxy: true)
        end
      end
    end

    def contains_bim?(defn)
      @contains_cache ||= {}
      return @contains_cache[defn] if @contains_cache.key?(defn)

      @contains_cache[defn] = false
      @contains_cache[defn] = defn.entities.any? do |e|
        BimData.instance?(e) && (BimData.element?(e) || contains_bim?(e.definition))
      end
    end

    # Numero di gruppi/componenti di primo livello non classificati e di
    # facce sciolte (per la verifica del modello).
    def unclassified_stats(model)
      @contains_cache = {}
      groups = model.entities.count do |e|
        BimData.instance?(e) && !BimData.element?(e) && !contains_bim?(e.definition)
      end
      [groups, model.entities.grep(Sketchup::Face).size]
    end

    def record(model, entity, world, with_mesh, proxy: false)
      data = proxy ? {} : BimData.read(entity)
      guid = data['guid']
      unless proxy || Guid.valid?(guid.to_s)
        guid = nil
      end
      if proxy
        seed = entity.respond_to?(:persistent_id) ? entity.persistent_id : entity.entityID
        guid = Guid.from_seed("#{model.guid}-#{seed}")
      end
      defn = entity.definition
      mat = entity.material
      type = ElementTypes[data['type']] || ElementTypes['proxy']
      color = mat ? [mat.color.red, mat.color.green, mat.color.blue] : type.color
      alpha = mat ? mat.alpha.to_f : type.alpha
      volume = Geometry.solid_volume(entity)
      name = entity.name.to_s
      name = defn.name.to_s if name.empty? && entity.is_a?(Sketchup::ComponentInstance)
      rec = {
        entity: entity,
        guid: guid,
        type: proxy ? 'proxy' : data['type'],
        name: name,
        object_type: proxy ? defn.name : data['object_type'],
        predefined: data['predefined'],
        level: data['level'],
        material: data['material'].to_s.empty? && mat ? mat.display_name : data['material'],
        props: data['props'] || {},
        custom: data['custom'] || {},
        host: data['host'],
        operation: entity.get_attribute(BimData::DICT, 'operation'),
        tag: entity.respond_to?(:persistent_id) ? entity.persistent_id.to_s : nil,
        color: color,
        alpha: alpha,
        solid: volume > 0,
        z_min: world_bounds_min_z(defn, world),
        measures: measures(defn, world, volume, data['type'] == 'wall' ? 'y' : 'z')
      }
      add_layers(model, entity, rec) unless proxy
      if with_mesh
        rec[:mesh] = mesh(defn, world)
        parts = part_children(defn)
        unless parts.empty?
          rec[:mesh_parts] = parts.map do |child|
            m = child.material
            { mesh: mesh(child.definition, world * child.transformation),
              color: m ? [m.color.red, m.color.green, m.color.blue] : color, alpha: m ? m.alpha.to_f : alpha }
          end
        end
      end
      rec
    end

    # Stratigrafia di muri e solai (dalla loro tipologia) per abaco e IFC.
    def add_layers(model, entity, rec)
      type = if rec[:type] == 'wall'
               Builder.parametric_wall?(entity) ? Builder.wall_type(model, entity) : nil
             else
               Builder.slab_type(model, entity)
             end
      return unless type

      rec[:layer_set_name] = type['name']
      rec[:layers] = type['layers'].map do |l|
        { name: l['name'], material: l['material'], thickness: l['thickness'].to_f, function: l['function'] }
      end
    end

    # Sotto-gruppi con geometria e colore propri: strati di muri e solai,
    # parti (telaio, anta, vetro) di porte e finestre.
    def part_children(defn)
      defn.entities.select do |e|
        BimData.instance?(e) && (!e.get_attribute(BimData::DICT, 'layer').nil? ||
                                 !e.get_attribute(BimData::DICT, 'part').nil?)
      end
    end

    # Sotto-gruppi che rappresentano gli strati di un muro o di un solaio.
    def layer_children(defn)
      defn.entities.select do |e|
        BimData.instance?(e) && !e.get_attribute(BimData::DICT, 'layer').nil?
      end
    end

    def world_bounds_min_z(defn, world)
      bb = defn.bounds
      zs = (0..7).map { |i| bb.corner(i).transform(world).z }
      zs.min.to_f * IN_TO_M
    end

    # Misure di base nel sistema locale dell'elemento (in metri).
    # layer_axis: asse lungo cui si susseguono gli strati ('y' nei muri,
    # 'z' nei solai), per escludere le facce di contatto tra gli strati.
    def measures(defn, world, volume, layer_axis = 'y')
      sx, sy, sz = Geometry.scales(world)
      bb = defn.bounds
      areas = Hash.new(0.0)
      perimeter = [0.0, 0.0] # [area faccia superiore maggiore, suo perimetro]
      layered = !layer_children(defn).empty?
      each_face(defn.entities, Geom::Transformation.new) do |face, local|
        area = face.area(world * local).to_f * IN2_TO_M2
        n = face.normal.transform(local)
        n.normalize! if n.length > 0
        bucket = axis_bucket(n)
        # Elementi a strati: le facce di contatto tra gli strati non sono superfici dell'elemento.
        next if layered && bucket[1] == layer_axis && !outer_face?(face, local, bb, bucket)

        areas[bucket] += area
        if bucket == 'pz' && area > perimeter[0]
          len = face.outer_loop.edges.sum { |e| e.length.to_f * edge_scale(e, world * local) }
          perimeter = [area, len * IN_TO_M]
        end
      end
      {
        length: bb.width.to_f * sx * IN_TO_M,
        width: bb.height.to_f * sy * IN_TO_M,
        height: bb.depth.to_f * sz * IN_TO_M,
        volume: volume > 0 ? volume.to_f * IN3_TO_M3 : nil,
        perimeter: perimeter[1] > 0 ? perimeter[1] : nil,
        areas: areas
      }
    end

    def outer_face?(face, local, bb, bucket)
      p = face.vertices.first.position.transform(local)
      if bucket[1] == 'z'
        (p.z - (bucket == 'pz' ? bb.max.z : bb.min.z)).abs < 1.mm
      else
        (p.y - (bucket == 'py' ? bb.max.y : bb.min.y)).abs < 1.mm
      end
    end

    def edge_scale(edge, tr)
      v = edge.line[1]
      v.transform(tr).length.to_f
    end

    def axis_bucket(n)
      return 'px' if n.x > AXIS_TOL
      return 'nx' if n.x < -AXIS_TOL
      return 'py' if n.y > AXIS_TOL
      return 'ny' if n.y < -AXIS_TOL
      return 'pz' if n.z > AXIS_TOL
      return 'nz' if n.z < -AXIS_TOL
      return 'up' if n.z > VERTICAL_TOL
      return 'down' if n.z < -VERTICAL_TOL

      'other'
    end

    def each_face(ents, tr, &block)
      ents.each do |e|
        if e.is_a?(Sketchup::Face)
          yield e, tr
        elsif BimData.instance?(e)
          each_face(e.definition.entities, tr * e.transformation, &block)
        end
      end
    end

    # Mesh triangolata in coordinate mondo (metri), vertici condivisi.
    def mesh(defn, world)
      points = []
      index = {}
      triangles = []
      each_face(defn.entities, world) do |face, tr|
        m = face.mesh(0)
        m.transform!(tr)
        ids = (1..m.count_points).map do |i|
          p = m.point_at(i)
          xyz = [p.x.to_f * IN_TO_M, p.y.to_f * IN_TO_M, p.z.to_f * IN_TO_M]
          key = xyz.map { |c| (c * 1_000_000).round }
          index[key] ||= begin
            points << xyz
            points.size - 1
          end
        end
        m.polygons.each do |poly|
          idx = poly.map { |i| ids[i.abs - 1] }
          (1...(idx.size - 1)).each do |k|
            tri = [idx[0], idx[k], idx[k + 1]]
            triangles << tri if tri.uniq.size == 3
          end
        end
      end
      { points: points, triangles: triangles }
    end
  end
end
