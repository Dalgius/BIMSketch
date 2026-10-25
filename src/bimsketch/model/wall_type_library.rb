# frozen_string_literal: true

require 'json'

module BIMSketch
  # Libreria delle tipologie di muro salvata nel modello SketchUp.
  module WallTypeLibrary
    DICT = 'BIMSketch_WallTypes'
    MATERIAL_PREFIX = 'BIM Strato - '

    module_function

    def all(model = Sketchup.active_model)
      raw = model.get_attribute(DICT, 'types')
      raw ? WallTypes.normalize(JSON.parse(raw)) : WallTypes.default_library
    rescue JSON::ParserError
      WallTypes.default_library
    end

    def save(model, types)
      list = WallTypes.normalize(types)
      model.set_attribute(DICT, 'types', JSON.generate(list))
      list
    end

    def find(model, id)
      return nil if id.to_s.empty?

      WallTypes.find(all(model), id)
    end

    # Materiale SketchUp di uno strato (creato al primo uso, colore per funzione).
    def material_for(model, layer)
      name = MATERIAL_PREFIX + layer['material'].to_s
      mat = model.materials[name]
      return mat if mat

      mat = model.materials.add(name)
      mat.color = Sketchup::Color.new(*WallTypes.color(layer))
      mat
    end

    # Fasce degli strati per Geometry.build_wall (unità interne).
    def geometry_layers(model, type, thickness, flipped)
      WallTypes.bands(type, thickness, flipped: flipped).map do |y0, y1, layer, _index|
        [y0, y1, layer['name'], material_for(model, layer)]
      end
    end
  end
end
