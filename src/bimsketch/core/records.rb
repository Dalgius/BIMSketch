# frozen_string_literal: true

require_relative 'element_types'
require_relative 'quantities'
require_relative 'level_list'
require_relative 'guid'
require_relative 'wall_types'

module BIMSketch
  # Operazioni pure sui "record" degli elementi BIM raccolti dal modello.
  #
  # Record (hash):
  #   guid:, type:, name:, object_type:, predefined:, level:, material:,
  #   props: { 'LoadBearing' => true, ... }, custom: { 'Codice' => 'A1', ... },
  #   measures: (vedi Quantities), mesh: { points:, triangles: } (opzionale),
  #   color: [r,g,b] 0-255, alpha: 0..1, host:, solid:, tag:, z_min: (m)
  #   layers: [{ name:, material:, thickness: (m), function: }] (stratigrafia, facoltativa),
  #   layer_set_name:, mesh_parts: [{ mesh:, color:, alpha: }] (geometria per strato)
  module Records
    CUSTOM_PSET = 'BIMSketch_Proprieta'

    module_function

    def type_of(rec)
      ElementTypes[rec[:type]] || ElementTypes['proxy']
    end

    def display_name(rec)
      n = rec[:name].to_s.strip
      n.empty? ? type_of(rec).label : n
    end

    def quantities(rec)
      Quantities.for_type(type_of(rec).key, rec[:measures] || {})
    end

    # Livello effettivo del record: quello assegnato se esiste, altrimenti
    # quello ricavato dalla quota minima dell'elemento.
    def resolve_level(rec, levels)
      lvl = LevelList.find(levels, rec[:level]) if rec[:level]
      lvl || LevelList.for_z(levels, rec[:z_min].to_f)
    end

    # Hash pronto per IfcWriter#add_element.
    def to_ifc_element(rec, levels)
      type = type_of(rec)
      level = resolve_level(rec, levels)
      qty = quantities(rec)
      psets = []
      props = (type.props || []).map do |pd|
        v = ElementTypes.coerce(pd.type, (rec[:props] || {})[pd.name])
        v.nil? ? nil : { name: pd.name, type: pd.type, value: v }
      end.compact
      psets << { name: type.pset, props: props } if type.pset && !props.empty?
      custom = (rec[:custom] || {}).map do |k, v|
        k.to_s.strip.empty? || v.to_s.strip.empty? ? nil : { name: k.to_s, type: :label, value: v.to_s }
      end.compact
      psets << { name: CUSTOM_PSET, props: custom } unless custom.empty?
      qtos = type.qto && !qty.empty? ? [{ name: type.qto, quantities: qty }] : []

      color = rec[:color] ? rec[:color].first(3).map { |c| c.to_f / 255.0 } : nil
      el = {
        guid: rec[:guid], ifc_class: type.ifc_class, name: display_name(rec),
        description: rec[:description], object_type: blank(rec[:object_type]),
        predefined: rec[:predefined], tag: rec[:tag], storey_id: level && level['id'],
        material: rec[:material], color: color, transparency: 1.0 - (rec[:alpha] || 1.0).to_f,
        mesh: rec[:mesh], psets: psets, qtos: qtos
      }
      unless Array(rec[:layers]).empty?
        el[:layers] = rec[:layers].map do |l|
          { name: l[:name], material: l[:material], thickness: l[:thickness],
            category: WallTypes::FUNCTIONS[l[:function].to_s] }
        end
        el[:layer_set_name] = rec[:layer_set_name]
      end
      if rec[:mesh_parts]
        el[:mesh_parts] = rec[:mesh_parts].map do |part|
          { mesh: part[:mesh], color: part[:color] && part[:color].first(3).map { |c| c.to_f / 255.0 },
            transparency: 1.0 - (part[:alpha] || 1.0).to_f }
        end
      end
      if %w[door window].include?(type.key)
        el[:overall_width] = Quantities.value(qty, 'Width')
        el[:overall_height] = Quantities.value(qty, 'Height')
        el[:operation] = rec[:operation] unless rec[:operation].to_s.empty?
      end
      el
    end

    def blank(value)
      s = value.to_s.strip
      s.empty? ? nil : s
    end

    SCHEDULE_COLUMNS = [
      ['type', 'Categoria'], ['name', 'Nome'], ['object_type', 'Tipologia'],
      ['level', 'Livello'], ['material', 'Materiale'], ['length', 'Lunghezza (m)'],
      ['width', 'Spessore/Larghezza (m)'], ['height', 'Altezza (m)'], ['area', 'Superficie (m²)'],
      ['volume', 'Volume (m³)'], ['guid', 'IFC GlobalId']
    ].freeze

    # Righe dell'abaco delle quantità.
    def schedule_rows(records, levels)
      records.map do |rec|
        type = type_of(rec)
        d = Quantities.derive(rec[:measures] || {})
        qty = quantities(rec)
        area = type.schedule_area ? Quantities.value(qty, type.schedule_area) : nil
        level = resolve_level(rec, levels)
        {
          'guid' => rec[:guid], 'type_key' => type.key, 'type' => type.label,
          'name' => display_name(rec), 'object_type' => rec[:object_type].to_s,
          'level' => level ? level['name'] : '', 'level_id' => level ? level['id'] : '',
          'material' => rec[:material].to_s,
          'length' => round(d[:length]), 'width' => round(d[:width]),
          'height' => round(d[:height]), 'area' => round(area),
          'volume' => round(Quantities.value(qty, 'NetVolume') || d[:volume])
        }
      end
    end

    def round(value, decimals = 3)
      value.nil? ? nil : value.round(decimals)
    end

    # Totali per categoria: { 'Muri' => { count:, area:, volume:, length: } }
    def totals(rows)
      rows.group_by { |r| r['type'] }.map do |label, rs|
        {
          'type' => label, 'count' => rs.size,
          'length' => sum(rs, 'length'), 'area' => sum(rs, 'area'), 'volume' => sum(rs, 'volume')
        }
      end
    end

    def sum(rows, key)
      rows.map { |r| r[key] }.compact.sum.round(3)
    end

    # Computo dei materiali dagli strati di muri e solai: superficie netta del
    # muro (al netto delle aperture) o superficie del solaio per lo spessore
    # di ogni strato, sommati per materiale.
    def material_takeoff(records)
      totals = Hash.new { |h, k| h[k] = { 'area' => 0.0, 'volume' => 0.0, 'elements' => 0 } }
      records.each do |rec|
        layers = Array(rec[:layers])
        next if layers.empty?

        q = quantities(rec)
        area = Quantities.value(q, 'NetSideArea') || Quantities.value(q, 'GrossArea')
        next unless area

        layers.each do |l|
          t = totals[l[:material].to_s.empty? ? l[:name].to_s : l[:material].to_s]
          t['area'] += area
          t['volume'] += area * l[:thickness].to_f
          t['elements'] += 1
        end
      end
      totals.map do |material, t|
        { 'material' => material, 'area' => t['area'].round(3), 'volume' => t['volume'].round(4),
          'elements' => t['elements'] }
      end.sort_by { |r| r['material'] }
    end

    def takeoff_csv(rows)
      lines = [['Materiale', 'Superficie (m²)', 'Volume (m³)', 'Strati'].map { |c| csv_cell(c) }.join(';')]
      rows.each do |r|
        lines << [csv_cell(r['material']), Quantities.format_number(r['area'], 3),
                  Quantities.format_number(r['volume'], 4), r['elements'].to_s].join(';')
      end
      "\uFEFF" + lines.join("\r\n") + "\r\n"
    end

    # CSV con separatore ';' e virgola decimale (compatibile con Excel in italiano).
    def to_csv(rows)
      lines = [SCHEDULE_COLUMNS.map { |_, label| csv_cell(label) }.join(';')]
      rows.each do |r|
        lines << SCHEDULE_COLUMNS.map do |key, _|
          v = r[key]
          v.is_a?(Numeric) ? Quantities.format_number(v, 3) : csv_cell(v.to_s)
        end.join(';')
      end
      "﻿" + lines.join("\r\n") + "\r\n"
    end

    def csv_cell(text)
      return text unless text =~ /[;"\r\n]/

      '"' + text.gsub('"', '""') + '"'
    end
  end

  # Verifica di coerenza del modello BIM.
  module Checker
    module_function

    # Restituisce un array di problemi:
    #   { severity: 'error'|'warning'|'info', code:, message:, guids: [] }
    def analyze(records, levels, unclassified_count: 0, loose_faces: 0)
      issues = []
      level_ids = levels.map { |l| l['id'] }

      records.group_by { |r| r[:guid] }.each do |g, rs|
        next if rs.size < 2

        issues << issue('error', 'duplicate_guid',
                        "#{rs.size} elementi condividono lo stesso GlobalId (#{g}): " \
                        'probabile copia di un elemento.', rs)
      end

      invalid = records.reject { |r| Guid.valid?(r[:guid].to_s) }
      unless invalid.empty?
        issues << issue('error', 'invalid_guid', "#{invalid.size} elementi senza GlobalId valido.",
                        invalid)
      end

      no_level = records.reject { |r| level_ids.include?(r[:level]) }
      unless no_level.empty?
        issues << issue('warning', 'no_level',
                        "#{no_level.size} elementi senza livello assegnato (verrà dedotto dalla quota).",
                        no_level)
      end

      not_solid = records.select { |r| Records.type_of(r).needs_volume && !r[:solid] }
      unless not_solid.empty?
        issues << issue('warning', 'not_solid',
                        "#{not_solid.size} elementi strutturali non sono solidi chiusi: " \
                        'il volume non può essere calcolato.', not_solid)
      end

      guids = records.map { |r| r[:guid] }
      orphans = records.select do |r|
        %w[door window].include?(r[:type]) && (r[:host].to_s.empty? || !guids.include?(r[:host]))
      end
      unless orphans.empty?
        issues << issue('info', 'orphan_opening',
                        "#{orphans.size} porte/finestre non sono associate a un muro.", orphans)
      end

      no_material = records.select { |r| r[:material].to_s.strip.empty? && r[:type] != 'space' }
      unless no_material.empty?
        issues << issue('info', 'no_material', "#{no_material.size} elementi senza materiale BIM.",
                        no_material)
      end

      if unclassified_count.positive?
        issues << { severity: 'warning', code: 'unclassified', guids: [],
                    message: "#{unclassified_count} gruppi/componenti non sono classificati: " \
                             "non saranno esportati come elementi BIM." }
      end
      if loose_faces.positive?
        issues << { severity: 'info', code: 'loose_geometry', guids: [],
                    message: "#{loose_faces} facce sciolte nel modello non appartengono ad alcun elemento." }
      end
      issues
    end

    def issue(severity, code, message, records)
      { severity: severity, code: code, message: message, guids: records.map { |r| r[:guid] }.uniq }
    end
  end
end
