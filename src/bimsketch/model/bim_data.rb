# frozen_string_literal: true

require 'json'

module BIMSketch
  # Lettura/scrittura dei dati BIM salvati negli attributi delle entità
  # (gruppi e istanze di componenti) di SketchUp.
  module BimData
    DICT = 'BIMSketch'

    module_function

    def instance?(entity)
      entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
    end

    def element?(entity)
      instance?(entity) && entity.valid? && !entity.get_attribute(DICT, 'type').nil?
    end

    def type_key(entity)
      entity.get_attribute(DICT, 'type')
    end

    def type(entity)
      ElementTypes[type_key(entity)]
    end

    def guid(entity)
      entity.get_attribute(DICT, 'guid')
    end

    def level_id(entity)
      entity.get_attribute(DICT, 'level')
    end

    def json_attr(entity, key)
      raw = entity.get_attribute(DICT, key)
      raw ? JSON.parse(raw) : {}
    rescue JSON::ParserError
      {}
    end

    # Dati BIM dell'entità come hash serializzabile.
    def read(entity)
      {
        'type' => type_key(entity),
        'guid' => guid(entity),
        'name' => entity.name.to_s,
        'object_type' => entity.get_attribute(DICT, 'object_type').to_s,
        'predefined' => entity.get_attribute(DICT, 'predefined').to_s,
        'level' => level_id(entity).to_s,
        'material' => entity.get_attribute(DICT, 'material').to_s,
        'host' => entity.get_attribute(DICT, 'host').to_s,
        'props' => json_attr(entity, 'props'),
        'custom' => json_attr(entity, 'custom')
      }
    end

    # Aggiorna i dati BIM (solo le chiavi presenti in data).
    def write(entity, data)
      if data.key?('type') && ElementTypes[data['type']] && data['type'] != type_key(entity)
        classify(entity, data['type'])
      end
      entity.name = data['name'].to_s if data.key?('name')
      %w[object_type predefined level material host].each do |k|
        entity.set_attribute(DICT, k, data[k].to_s) if data.key?(k)
      end
      entity.set_attribute(DICT, 'props', JSON.generate(clean_props(entity, data['props']))) if data['props']
      entity.set_attribute(DICT, 'custom', JSON.generate(data['custom'])) if data['custom'].is_a?(Hash)
      apply_material(entity, data['material']) if data.key?('material')
      entity
    end

    # Converte i valori dei Pset nei tipi corretti, scartando le chiavi sconosciute.
    def clean_props(entity, props)
      t = type(entity)
      return {} unless t && props.is_a?(Hash)

      t.props.each_with_object({}) do |pd, h|
        v = ElementTypes.coerce(pd.type, props[pd.name])
        h[pd.name] = v unless v.nil?
      end
    end

    # Classifica un gruppo/componente come elemento BIM del tipo indicato.
    def classify(entity, key, level: nil, name: nil)
      t = ElementTypes[key]
      raise ArgumentError, "Tipo sconosciuto: #{key}" unless t

      model = entity.model
      entity.set_attribute(DICT, 'type', t.key)
      ensure_guid(entity)
      lvl = level || level_id(entity) || Levels.for_entity(model, entity)['id']
      entity.set_attribute(DICT, 'level', lvl)
      predefined = entity.get_attribute(DICT, 'predefined').to_s
      entity.set_attribute(DICT, 'predefined', t.predefined.first) unless t.predefined.include?(predefined)
      unless entity.get_attribute(DICT, 'props')
        defaults = t.props.each_with_object({}) { |pd, h| h[pd.name] = pd.default unless pd.default.nil? }
        entity.set_attribute(DICT, 'props', JSON.generate(defaults))
      end
      entity.name = name if name && !name.empty?
      entity.layer = model.layers.add(ElementTypes.tag_name(t.key))
      entity.material = default_material(model, t) if entity.material.nil?
      apply_native_classification(entity, t.ifc_class)
      entity
    end

    def declassify(entity)
      entity.attribute_dictionaries.delete(DICT) if entity.attribute_dictionaries
    end

    def ensure_guid(entity)
      g = guid(entity)
      return g if Guid.valid?(g.to_s)

      regenerate_guid(entity)
    end

    def regenerate_guid(entity)
      g = Guid.generate
      entity.set_attribute(DICT, 'guid', g)
      g
    end

    # Materiale SketchUp predefinito per il tipo (colore della categoria).
    def default_material(model, type)
      name = "BIM #{type.label}"
      mat = model.materials[name]
      return mat if mat

      mat = model.materials.add(name)
      mat.color = Sketchup::Color.new(*type.color)
      mat.alpha = type.alpha if type.alpha < 1.0
      mat
    end

    # Il nome del materiale BIM viene usato anche come materiale SketchUp
    # se nel modello ne esiste già uno con quel nome.
    def apply_material(entity, name)
      return if name.to_s.strip.empty?

      mat = entity.model.materials[name.to_s]
      entity.material = mat if mat
    end

    # Applica anche la classificazione nativa di SketchUp (schema IFC caricato
    # nel modello), utile per l'esportatore IFC integrato di SketchUp Pro.
    def apply_native_classification(entity, ifc_class)
      return unless entity.respond_to?(:definition)

      defn = entity.definition
      return unless defn.respond_to?(:add_classification)

      schema = entity.model.classifications.find { |c| c.name.to_s.start_with?('IFC') }
      defn.add_classification(schema.name, ifc_class) if schema
    rescue StandardError
      nil
    end
  end
end
