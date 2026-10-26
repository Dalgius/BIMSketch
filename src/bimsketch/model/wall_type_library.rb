# frozen_string_literal: true

require 'json'

module BIMSketch
  # Librerie delle tipologie (stratigrafie) salvate nel modello SketchUp:
  # kind 'wall' per i muri, 'slab' per solai e coperture.
  module WallTypeLibrary
    DICT = 'BIMSketch_WallTypes'
    DICTS = { 'wall' => DICT, 'slab' => 'BIMSketch_SlabTypes' }.freeze
    MATERIAL_PREFIX = 'BIM Strato - '

    module_function

    def all(model = Sketchup.active_model, kind: 'wall')
      raw = model.get_attribute(DICTS[kind], 'types')
      raw ? WallTypes.normalize(JSON.parse(raw), kind) : WallTypes.default_library(kind)
    rescue JSON::ParserError
      WallTypes.default_library(kind)
    end

    def save(model, types, kind: 'wall')
      list = WallTypes.normalize(types, kind)
      model.set_attribute(DICTS[kind], 'types', JSON.generate(list))
      list
    end

    def find(model, id, kind: 'wall')
      return nil if id.to_s.empty?

      WallTypes.find(all(model, kind: kind), id)
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

    # Finiture sulle due facce del muro (y = 0 e y = thickness), per il
    # risvolto nelle aperture: r_lo / r_hi spessori (0 se lo strato sulla
    # faccia non è una finitura), lo / hi strati sulle due facce.
    def reveal_info(type, thickness, flipped)
      bands = WallTypes.bands(type, thickness, flipped: flipped)
      fin = ->(band) { band[2]['function'] == 'finish' ? band[1] - band[0] : 0.0 }
      { r_lo: fin.call(bands.first), r_hi: fin.call(bands.last), lo: bands.first[2], hi: bands.last[2] }
    end

    # Fasce degli strati per Geometry.build_slab: [[z0, z1, nome, materiale], ...]
    # dall'intradosso (z = 0), alte in totale thickness (unità interne).
    def slab_layers(model, type, thickness)
      WallTypes.slab_bands(type, thickness).map do |z0, z1, layer, _index|
        [z0, z1, layer['name'], material_for(model, layer)]
      end
    end
  end
end
