# frozen_string_literal: true

module BIMSketch
  # Calcolo di una scala a rampa rettilinea (modulo puro Ruby, metri).
  module StairCalc
    BLONDEL = 0.63 # 2a + p
    MIN_TREAD = 0.25
    MAX_TREAD = 0.33

    module_function

    # Alzate e pedate per superare il dislivello height con alzate non oltre
    # max_riser; la pedata segue la regola di Blondel (2a + p = 63 cm).
    # L'ultima alzata arriva al piano superiore: le pedate sono una in meno.
    def compute(height, max_riser: 0.175, blondel: BLONDEL)
      risers = (height / max_riser - 1e-9).ceil
      risers = 2 if risers < 2
      riser = height / risers
      tread = (blondel - 2 * riser).clamp(MIN_TREAD, MAX_TREAD)
      treads = risers - 1
      { risers: risers, riser: riser, tread: tread, treads: treads, run: treads * tread, height: height }
    end

    # Scala con numero di alzate e pedata scelti (stessa forma di compute).
    def fixed(height, risers, tread)
      risers = [risers.to_i, 2].max
      { risers: risers, riser: height / risers, tread: tread.to_f, treads: risers - 1,
        run: (risers - 1) * tread.to_f, height: height }
    end

    # Valore della regola di Blondel (2a + p) in metri.
    def blondel(calc)
      2 * calc[:riser] + calc[:tread]
    end

    # Profilo laterale della rampa [[x, z], ...]: gradini dall'origine verso
    # +x, intradosso parallelo all'inclinazione con soletta di spessore waist.
    # La rampa finisce con l'ultima pedata (a quota height - alzata): l'ultima
    # alzata, fino al piano superiore, è il bordo del solaio di arrivo.
    def profile(calc, waist: 0.18)
      a = calc[:riser]
      p = calc[:tread]
      n = calc[:risers]
      pts = [[0.0, 0.0]]
      (n - 1).times do |i|
        pts << [i * p, (i + 1) * a]
        pts << [(i + 1) * p, (i + 1) * a]
      end
      # Intradosso: retta z = x·a/p - waist/cos(θ), tagliata sul pavimento.
      drop = waist * Math.sqrt(a * a + p * p) / p
      x_end = (n - 1) * p
      z_end = [x_end * a / p - drop, 0.0].max
      x0 = [drop * p / a, x_end].min
      pts << [x_end, z_end]
      pts << [x0, 0.0] if z_end.positive?
      pts
    end
  end
end
