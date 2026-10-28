# frozen_string_literal: true

require 'json'

module BIMSketch
  # Gestione dei livelli (IfcBuildingStorey) salvati nel modello SketchUp.
  module Levels
    DICT = 'BIMSketch_Levels'

    module_function

    def all(model = Sketchup.active_model)
      raw = model.get_attribute(DICT, 'levels')
      list = raw ? JSON.parse(raw) : nil
      LevelList.normalize(list || LevelList.default)
    rescue JSON::ParserError
      LevelList.default
    end

    def save(model, levels)
      list = LevelList.normalize(levels)
      model.set_attribute(DICT, 'levels', JSON.generate(list))
      set_current(model, list.first['id']) unless LevelList.find(list, current_id(model))
      list
    end

    def current_id(model = Sketchup.active_model)
      model.get_attribute(DICT, 'current') || all(model).first['id']
    end

    def current(model = Sketchup.active_model)
      levels = all(model)
      LevelList.find(levels, current_id(model)) || levels.first
    end

    def set_current(model, id)
      model.set_attribute(DICT, 'current', id)
    end

    def find(model, id)
      LevelList.find(all(model), id)
    end

    # Quota del livello corrente in unità interne SketchUp.
    def current_elevation(model = Sketchup.active_model)
      current(model)['elevation'].m
    end

    def current_height(model = Sketchup.active_model)
      current(model)['height'].m
    end

    # Livello in cui ricade un'entità (in base alla quota minima del bounding box).
    def for_entity(model, entity)
      LevelList.for_z(all(model), entity.bounds.min.z.to_m)
    end

    # Elementi BIM di primo livello appartenenti al livello indicato.
    def elements_on(model, id)
      model.entities.select { |e| BimData.element?(e) && BimData.level_id(e) == id }
    end

    # Salva i livelli e aggiorna gli elementi:
    # - se la quota di un livello cambia, i suoi elementi si spostano in verticale;
    # - muri e pilastri con altezza automatica prendono l'altezza del livello;
    # - le travi (estradosso sotto il livello superiore) seguono la variazione
    #   di altezza del livello.
    # Restituisce i livelli salvati; skipped_last_update indica quanti elementi
    # non sono stati adattati (modificati a mano o con aperture che non entrano).
    def update(model, new_levels, move_elements: true)
      old = all(model)
      @skipped = 0
      model.start_operation('BIMSketch: Modifica livelli', true)
      list = save(model, new_levels)
      list.each do |lvl|
        prev = LevelList.find(old, lvl['id'])
        elements = elements_on(model, lvl['id'])
        if move_elements && prev
          delta = lvl['elevation'] - prev['elevation']
          unless delta.abs < 1e-6
            tr = Geom::Transformation.translation([0, 0, delta.m])
            elements.each { |e| e.transform!(tr) }
          end
          dh = lvl['height'] - prev['height']
          unless dh.abs < 1e-6
            lift = Geom::Transformation.translation([0, 0, dh.m])
            elements.each do |e|
              next unless BimData.type_key(e) == 'beam' && e.get_attribute(BimData::DICT, 'auto_top') != false

              e.transform!(lift)
            end
          end
        end
        sync_heights(model, elements, lvl)
      end
      model.commit_operation
      list
    rescue StandardError
      model.abort_operation
      raise
    end

    def skipped_last_update
      @skipped.to_i
    end

    # Porta gli elementi sul livello indicato: ognuno si sposta in verticale
    # della differenza di quota tra il suo livello e quello nuovo (le travi
    # anche della differenza di altezza), insieme alle porte e finestre che
    # ospita; muri e pilastri con altezza automatica prendono l'altezza del
    # nuovo livello. Un elemento senza livello valido viene solo assegnato.
    # Va chiamato dentro un'operazione; restituisce il numero di elementi
    # la cui altezza non è stata adattata.
    def relocate(model, entities, to_id)
      to = find(model, to_id)
      return 0 unless to

      items = entities.select { |e| BimData.element?(e) }
      guids = items.map { |e| BimData.guid(e) }.compact
      hosted = model.active_entities.select do |e|
        BimData.element?(e) && guids.include?(e.get_attribute(BimData::DICT, 'host'))
      end
      @skipped = 0
      (items + hosted).uniq.each do |e|
        from = find(model, BimData.level_id(e))
        e.set_attribute(BimData::DICT, 'level', to['id'])
        next unless from && from['id'] != to['id']

        dz = to['elevation'] - from['elevation']
        dz += to['height'] - from['height'] if BimData.type_key(e) == 'beam' &&
                                               e.get_attribute(BimData::DICT, 'auto_top') != false
        e.transform!(Geom::Transformation.translation([0, 0, dz.m])) unless dz.abs < 1e-6
        sync_heights(model, [e], to)
      end
      @skipped
    end

    # Porta all'altezza del livello i muri e i pilastri con altezza automatica.
    def sync_heights(model, elements, lvl)
      elements.each do |e|
        info = Builder.element_height(model, e)
        next unless info && info[:auto]
        next if (info[:height] - Builder.auto_height(model, e, lvl)).abs < 0.5.mm

        @skipped = @skipped.to_i + 1 unless Builder.set_height(model, e, auto: true)
      end
    end

    # Mostra soltanto gli elementi del livello indicato (nil = mostra tutto).
    def isolate(model, id)
      model.start_operation('BIMSketch: Isola livello', true, false, true)
      model.entities.each do |e|
        next unless BimData.element?(e)

        e.hidden = !id.nil? && BimData.level_id(e) != id
      end
      model.commit_operation
    end

    # Crea una vista in pianta del livello: piano di sezione a 1,20 m dal
    # pavimento e scena con vista dall'alto in proiezione parallela.
    def create_plan_view(model, id)
      lvl = find(model, id)
      return unless lvl

      model.start_operation('BIMSketch: Vista in pianta', true)
      z = (lvl['elevation'] + [1.2, lvl['height'] * 0.9].min).m
      # La normale del piano punta verso la parte che resta visibile (verificato
      # in SketchUp 2026): verso il basso per conservare ciò che sta sotto il taglio.
      plane_name = "Pianta #{lvl['name']}"
      sp = model.entities.grep(Sketchup::SectionPlane).find { |e| e.respond_to?(:name) && e.name == plane_name }
      if sp
        sp.set_plane([0, 0, -1, z])
      else
        sp = model.entities.add_section_plane([0, 0, z], [0, 0, -1])
        sp.name = plane_name if sp.respond_to?(:name=)
      end
      sp.activate
      view = model.active_view
      bb = model.bounds
      center = bb.empty? ? Geom::Point3d.new(0, 0, 0) : bb.center
      eye = Geom::Point3d.new(center.x, center.y, z + 100.m)
      target = Geom::Point3d.new(center.x, center.y, z)
      camera = Sketchup::Camera.new(eye, target, Y_AXIS)
      camera.perspective = false
      view.camera = camera
      view.zoom_extents
      name = "Pianta - #{lvl['name']}"
      old_page = model.pages[name]
      model.pages.erase(old_page) if old_page && model.pages.respond_to?(:erase)
      page = model.pages.add(name)
      page.use_section_planes = true if page.respond_to?(:use_section_planes=)
      model.commit_operation
      page
    end

    # Torna alla vista 3D: nessun piano di sezione attivo, vista assonometrica
    # in prospettiva su tutto il modello, salvata nella scena "Vista 3D".
    def view_3d(model)
      model.start_operation('BIMSketch: Vista 3D', true)
      model.entities.active_section_plane = nil if model.entities.respond_to?(:active_section_plane=)
      if model.active_path
        model.active_entities.active_section_plane = nil if model.active_entities.respond_to?(:active_section_plane=)
      end
      bb = model.bounds
      center = bb.empty? ? Geom::Point3d.new(0, 0, 0) : bb.center
      d = bb.empty? ? 20.m : [bb.diagonal, 1.m].max
      eye = Geom::Point3d.new(center.x - d, center.y - d, center.z + d * 0.8)
      camera = Sketchup::Camera.new(eye, center, Z_AXIS)
      camera.perspective = true
      view = model.active_view
      view.camera = camera
      view.zoom_extents
      name = 'Vista 3D'
      old_page = model.pages[name]
      model.pages.erase(old_page) if old_page && model.pages.respond_to?(:erase)
      page = model.pages.add(name)
      page.use_section_planes = true if page.respond_to?(:use_section_planes=)
      model.commit_operation
      page
    end

    # Inverte il piano di sezione attivo nel contesto corrente.
    def reverse_active_section(model)
      sp = model.active_entities.grep(Sketchup::SectionPlane).find do |s|
        s.respond_to?(:active?) ? s.active? : true
      end
      return false unless sp

      model.start_operation('BIMSketch: Inverti sezione', true)
      sp.set_plane(sp.get_plane.map { |c| -c })
      model.commit_operation
      true
    end
  end
end
