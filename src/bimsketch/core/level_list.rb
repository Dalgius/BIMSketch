# frozen_string_literal: true

module BIMSketch
  # Logica pura della lista dei livelli (piani / IfcBuildingStorey).
  # Ogni livello è un hash: { 'id' => String, 'name' => String,
  # 'elevation' => Float (m), 'height' => Float (m) }.
  module LevelList
    TOLERANCE = 0.01 # m

    DEFAULT = [
      { 'id' => 'L0', 'name' => 'Piano Terra', 'elevation' => 0.0, 'height' => 3.0 }
    ].freeze

    module_function

    def default
      DEFAULT.map(&:dup)
    end

    # Pulisce e ordina per quota una lista proveniente da JSON/dialog.
    def normalize(levels)
      list = Array(levels).map do |l|
        {
          'id' => l['id'].to_s,
          'name' => l['name'].to_s.strip,
          'elevation' => to_f(l['elevation'], 0.0),
          'height' => [to_f(l['height'], 3.0), 0.1].max
        }
      end
      list.reject! { |l| l['id'].empty? }
      list.each { |l| l['name'] = "Livello #{l['id']}" if l['name'].empty? }
      list.uniq! { |l| l['id'] }
      list = default if list.empty?
      list.sort_by { |l| l['elevation'] }
    end

    def next_id(levels)
      used = levels.map { |l| l['id'] }
      i = levels.size
      i += 1 while used.include?("L#{i}")
      "L#{i}"
    end

    # Nuovo livello posto sopra il più alto esistente.
    def build_next(levels, name = nil)
      top = levels.max_by { |l| l['elevation'] }
      elevation = top ? top['elevation'] + top['height'] : 0.0
      height = top ? top['height'] : 3.0
      id = next_id(levels)
      { 'id' => id, 'name' => name || "Piano #{levels.size}", 'elevation' => elevation.round(4),
        'height' => height }
    end

    def find(levels, id)
      levels.find { |l| l['id'] == id }
    end

    # Livello che contiene la quota z (m): il più alto con quota <= z.
    def for_z(levels, z)
      sorted = levels.sort_by { |l| l['elevation'] }
      candidate = sorted.reverse.find { |l| l['elevation'] <= z + TOLERANCE }
      candidate || sorted.first
    end

    def to_f(value, fallback)
      Float(value.to_s.tr(',', '.'))
    rescue ArgumentError, TypeError
      fallback
    end
  end
end
