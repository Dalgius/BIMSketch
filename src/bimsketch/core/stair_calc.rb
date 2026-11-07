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
    # alzata, fino al piano superiore, è il bordo del solaio di arrivo (o del
    # pianerottolo). Con landing la rampa parte da un pianerottolo: niente
    # appoggio sul pavimento, l'intradosso scende fino all'origine.
    def profile(calc, waist: 0.18, landing: false)
      a = calc[:riser]
      p = calc[:tread]
      n = calc[:risers]
      drop = waist * Math.sqrt(a * a + p * p) / p
      pts = [[0.0, landing ? -drop : 0.0]]
      (n - 1).times do |i|
        pts << [i * p, (i + 1) * a]
        pts << [(i + 1) * p, (i + 1) * a]
      end
      # Intradosso: retta z = x·a/p - waist/cos(θ), tagliata sul pavimento.
      x_end = (n - 1) * p
      if landing
        pts << [x_end, x_end * a / p - drop]
        return pts
      end
      z_end = [x_end * a / p - drop, 0.0].max
      x0 = [drop * p / a, x_end].min
      pts << [x_end, z_end]
      pts << [x0, 0.0] if z_end.positive?
      pts
    end

    # Spessore verticale della soletta (waist misurato perpendicolare alla rampa).
    def drop(calc, waist)
      waist * Math.sqrt(calc[:riser]**2 + calc[:tread]**2) / calc[:tread]
    end

    # Scala a L: alzate della prima rampa, compresa quella che sale sul
    # pianerottolo (metà, arrotondata per eccesso; ogni rampa almeno 2).
    def l_split(risers)
      (risers / 2.0).ceil.clamp(2, [risers - 2, 2].max)
    end

    def valid_l?(risers, flight1)
      risers >= 4 && flight1.between?(2, risers - 2)
    end

    # Ingombri della scala a L (metri, sistema locale della prima rampa che
    # sale verso +x su 0 <= y <= width): pianerottolo quadrato di lato width
    # in fondo alla prima rampa, seconda rampa verso +y (turn 'left') o -y.
    def l_flights(calc, flight1, width)
      n2 = calc[:risers] - flight1
      p = calc[:tread]
      run1 = (flight1 - 1) * p
      { flight1: flight1, flight2: n2, run1: run1, run2: (n2 - 1) * p, landing_x: run1,
        landing_z: flight1 * calc[:riser] }
    end

    # Impronta in pianta [[x, y], ...] della scala (rettilinea o a L).
    def outline(calc, width, shape: 'straight', flight1: nil, turn: 'left')
      return [[0.0, 0.0], [calc[:run], 0.0], [calc[:run], width], [0.0, width]] unless shape == 'l'

      f = l_flights(calc, flight1, width)
      x0 = f[:run1]
      x1 = x0 + width
      if turn == 'right'
        y = -f[:run2]
        [[0.0, 0.0], [x0, 0.0], [x0, y], [x1, y], [x1, width], [0.0, width]]
      else
        y = width + f[:run2]
        [[0.0, 0.0], [x1, 0.0], [x1, y], [x0, y], [x0, width], [0.0, width]]
      end
    end
  end
end
