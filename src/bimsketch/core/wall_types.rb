# frozen_string_literal: true

require 'json'

module BIMSketch
  # Tipologie di muro con stratigrafia (modulo puro Ruby).
  #
  # Tipologia (hash):
  #   'id' => 'WT1', 'name' => 'Muro esterno 42,5 cm',
  #   'layers' => [{ 'name' => 'Intonaco interno', 'material' => 'Intonaco di calce',
  #                  'thickness' => 0.015 (m), 'lambda' => 0.7 (W/mK, facoltativa),
  #                  'function' => 'finish' }, ...]
  #
  # Gli strati sono elencati dalla faccia "lo" del muro (a destra della
  # direzione di disegno) verso la faccia "hi" (a sinistra); "inverti
  # stratigrafia" li percorre al contrario.
  module WallTypes
    FUNCTIONS = {
      'structure' => 'Struttura', 'insulation' => 'Isolante', 'finish' => 'Finitura', 'other' => 'Altro'
    }.freeze

    COLORS = {
      'structure' => [190, 110, 80], 'insulation' => [244, 214, 110], 'finish' => [236, 232, 222],
      'other' => [170, 170, 170]
    }.freeze

    # Resistenze superficiali (UNI EN ISO 6946, flusso orizzontale), m²K/W.
    RSI = 0.13
    RSE = 0.04

    DEFAULT_LIBRARY = [
      { 'id' => 'WT1', 'name' => 'Muro esterno laterizio + cappotto',
        'layers' => [
          { 'name' => 'Rasatura esterna', 'material' => 'Rasante minerale', 'thickness' => 0.01,
            'lambda' => 0.9, 'function' => 'finish' },
          { 'name' => 'Cappotto', 'material' => 'EPS con grafite', 'thickness' => 0.10,
            'lambda' => 0.031, 'function' => 'insulation' },
          { 'name' => 'Muratura', 'material' => 'Blocco in laterizio porizzato', 'thickness' => 0.30,
            'lambda' => 0.20, 'function' => 'structure' },
          { 'name' => 'Intonaco interno', 'material' => 'Intonaco di calce e gesso', 'thickness' => 0.015,
            'lambda' => 0.70, 'function' => 'finish' }
        ] },
      { 'id' => 'WT2', 'name' => 'Muro in c.a.',
        'layers' => [
          { 'name' => 'Intonaco', 'material' => 'Intonaco cementizio', 'thickness' => 0.015,
            'lambda' => 1.0, 'function' => 'finish' },
          { 'name' => 'Calcestruzzo armato', 'material' => 'Calcestruzzo C25/30', 'thickness' => 0.30,
            'lambda' => 2.3, 'function' => 'structure' },
          { 'name' => 'Intonaco', 'material' => 'Intonaco cementizio', 'thickness' => 0.015,
            'lambda' => 1.0, 'function' => 'finish' }
        ] },
      { 'id' => 'WT3', 'name' => 'Tramezzo in laterizio',
        'layers' => [
          { 'name' => 'Intonaco', 'material' => 'Intonaco di calce e gesso', 'thickness' => 0.015,
            'lambda' => 0.70, 'function' => 'finish' },
          { 'name' => 'Forato', 'material' => 'Laterizio forato', 'thickness' => 0.08,
            'lambda' => 0.40, 'function' => 'structure' },
          { 'name' => 'Intonaco', 'material' => 'Intonaco di calce e gesso', 'thickness' => 0.015,
            'lambda' => 0.70, 'function' => 'finish' }
        ] }
    ].freeze

    MIN_THICKNESS = 0.001 # m

    module_function

    def default_library
      JSON.parse(JSON.generate(DEFAULT_LIBRARY))
    end

    def to_f(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Float(value.to_s.strip.tr(',', '.'))
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_layer(layer)
      t = to_f(layer['thickness'])
      return nil unless t && t >= MIN_THICKNESS

      lam = to_f(layer['lambda'])
      fn = FUNCTIONS.key?(layer['function']) ? layer['function'] : 'other'
      material = layer['material'].to_s.strip
      name = layer['name'].to_s.strip
      {
        'name' => name.empty? ? (material.empty? ? FUNCTIONS[fn] : material) : name,
        'material' => material.empty? ? name : material,
        'thickness' => t.round(5),
        'lambda' => lam && lam.positive? ? lam : nil,
        'function' => fn
      }
    end

    # Pulisce una lista di tipologie proveniente dal dialog/JSON: scarta gli
    # strati non validi e le tipologie senza strati, rende gli id univoci.
    def normalize(types)
      used = []
      Array(types).each_with_object([]) do |t, out|
        layers = Array(t['layers']).map { |l| normalize_layer(l) }.compact
        next if layers.empty?

        id = t['id'].to_s.strip
        id = next_id(used) if id.empty? || used.include?(id)
        used << id
        name = t['name'].to_s.strip
        out << { 'id' => id, 'name' => name.empty? ? "Tipologia #{id}" : name, 'layers' => layers }
      end
    end

    def next_id(ids)
      i = 1
      i += 1 while ids.include?("WT#{i}")
      "WT#{i}"
    end

    def find(types, id)
      Array(types).find { |t| t['id'] == id }
    end

    # Spessore totale (m).
    def thickness(type)
      type['layers'].sum { |l| l['thickness'].to_f }
    end

    # Trasmittanza U (W/m²K) secondo UNI EN ISO 6946 per strati omogenei;
    # nil se uno strato non ha la conduttività. external: false per i muri
    # interni (resistenza superficiale interna su entrambe le facce).
    def u_value(type, external: true)
      layers = type['layers']
      return nil if layers.empty? || layers.any? { |l| l['lambda'].nil? || l['lambda'].to_f <= 0 }

      r = layers.sum { |l| l['thickness'].to_f / l['lambda'].to_f }
      r += RSI + (external ? RSE : RSI)
      1.0 / r
    end

    # Fasce degli strati nel sistema locale del muro, scalate su total
    # (stessa unità del muro): [[y0, y1, layer, index], ...] da y = 0 (faccia lo).
    def bands(type, total, flipped: false)
      layers = type['layers'].each_with_index.to_a
      layers = layers.reverse if flipped
      sum = thickness(type)
      scale = sum.positive? ? total.to_f / sum : 0.0
      y = 0.0
      layers.map do |layer, index|
        y0 = y
        y += layer['thickness'].to_f * scale
        [y0, y, layer, index]
      end
    end

    def color(layer)
      COLORS[layer['function']] || COLORS['other']
    end

    # Descrizione breve della stratigrafia, es. "1 + 10 + 30 + 1,5 cm".
    def summary(type)
      type['layers'].map { |l| format('%g', (l['thickness'].to_f * 100).round(1)).tr('.', ',') }.join(' + ') + ' cm'
    end
  end
end
