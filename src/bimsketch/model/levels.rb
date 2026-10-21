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

    # Salva i livelli e, se la quota di un livello è cambiata, sposta in verticale
    # gli elementi che vi appartengono.
    def update(model, new_levels, move_elements: true)
      old = all(model)
      model.start_operation('BIMSketch: Modifica livelli', true)
      list = save(model, new_levels)
      if move_elements
        list.each do |lvl|
          prev = LevelList.find(old, lvl['id'])
          next unless prev

          delta = lvl['elevation'] - prev['elevation']
          next if delta.abs < 1e-6

          tr = Geom::Transformation.translation([0, 0, delta.m])
          elements_on(model, lvl['id']).each { |e| e.transform!(tr) }
        end
      end
      model.commit_operation
      list
    rescue StandardError
      model.abort_operation
      raise
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
      # La normale indica il lato rimosso dal taglio: si conserva la parte sotto.
      # Se necessario la sezione si può invertire con "Inverti sezione attiva".
      sp = model.entities.add_section_plane([0, 0, z], [0, 0, 1])
      sp.name = "Pianta #{lvl['name']}" if sp.respond_to?(:name=)
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
