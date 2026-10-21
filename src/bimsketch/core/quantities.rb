# frozen_string_literal: true

require_relative 'element_types'

module BIMSketch
  # Calcolo delle quantità (Qto_*) a partire da misure geometriche di base.
  # Modulo puro Ruby: le misure vengono raccolte dal lato SketchUp
  # (vedi Collector) e qui trasformate nelle quantità IFC.
  #
  # Misure di base attese (unità SI: m, m², m³), tutte nel sistema locale
  # dell'elemento (x = asse dell'elemento, y = spessore, z = altezza):
  #   :length, :width, :height  estensioni del bounding box locale
  #   :volume                   volume del solido (nil se non è un solido)
  #   :perimeter                perimetro della faccia superiore principale
  #   :areas                    aree delle facce per orientamento:
  #                             'px','nx','py','ny','pz','nz' (allineate agli assi),
  #                             'up','down' (inclinate), 'other' (verticali generiche)
  module Quantities
    UNITS = { length: 'm', area: 'm²', volume: 'm³' }.freeze

    module_function

    # Restituisce un hash con tutte le misure derivate.
    def derive(m)
      a = Hash.new(0.0)
      (m[:areas] || {}).each { |k, v| a[k.to_s] = v.to_f }
      length = m[:length].to_f
      width = m[:width].to_f
      height = m[:height].to_f
      top = a['pz'] + a['up']
      {
        length: length,
        width: width,
        height: height,
        volume: m[:volume] && m[:volume] > 0 ? m[:volume].to_f : nil,
        perimeter: m[:perimeter] ? m[:perimeter].to_f : nil,
        footprint_area: a['nz'] + a['down'],
        top_area: top,
        side_area: a['px'] + a['nx'] + a['py'] + a['ny'] + a['other'],
        surface_area: a.values.sum,
        gross_side_area: length * height,
        net_side_area: [a['py'], a['ny']].max,
        gross_volume: length * width * height,
        prism_volume: top * height,
        cross_section_yz: width * height,
        opening_area: length * height
      }
    end

    # Quantità del Qto standard per il tipo indicato.
    # Restituisce un array di hash { name:, label:, kind:, value: } (solo valori validi).
    def for_type(type_key, measures)
      type = ElementTypes[type_key]
      return [] unless type

      d = derive(measures)
      type.quantities.each_with_object([]) do |qd, out|
        v = d[qd.measure]
        next if v.nil? || !v.finite? || v <= 0

        out << { name: qd.name, label: qd.label, kind: qd.kind, value: v }
      end
    end

    # Valore della quantità indicata (o nil).
    def value(list, name)
      q = list.find { |x| x[:name] == name }
      q && q[:value]
    end

    # Formatta un numero con la virgola decimale (convenzione italiana).
    def format_number(value, decimals = 2)
      return '' if value.nil?

      format("%.#{decimals}f", value).tr('.', ',')
    end
  end
end
