# frozen_string_literal: true

module BIMSketch
  # Impostazioni utente persistenti (valori in millimetri).
  module Settings
    SECTION = 'BIMSketch'

    DEFAULTS = {
      'wall_thickness' => 300, 'wall_height' => 0, 'wall_align' => 'center', 'wall_type' => '',
      'slab_thickness' => 250, 'slab_type' => '',
      'column_width' => 300, 'column_depth' => 300,
      'beam_width' => 300, 'beam_height' => 500, 'stair_width' => 1000, 'stair_riser' => 175,
      'door_type' => 'D1', 'window_type' => 'W2',
      'door_width' => 900, 'door_height' => 2100,
      'window_width' => 1200, 'window_height' => 1400, 'window_sill' => 900
    }.freeze

    ALIGN_LABELS = { 'center' => 'Asse', 'left' => 'Sinistra', 'right' => 'Destra' }.freeze

    module_function

    def get(key)
      Sketchup.read_default(SECTION, key, DEFAULTS[key])
    end

    def set(key, value)
      Sketchup.write_default(SECTION, key, value)
    end

    # Lunghezza in unità interne SketchUp (pollici) da un valore in mm.
    def length(key)
      get(key).to_f.mm
    end

    # Tipologia di muro predefinita per lo strumento Muro (nil = spessore libero).
    def wall_type(model = Sketchup.active_model)
      WallTypeLibrary.find(model, get('wall_type'))
    end

    # Tipologia di solaio predefinita per lo strumento Solaio (nil = spessore libero).
    def slab_type(model = Sketchup.active_model)
      WallTypeLibrary.find(model, get('slab_type'), kind: 'slab')
    end

    # Tipologia di porta o finestra corrente per lo strumento ('door'/'window').
    def opening_type(kind)
      OpeningTypes.for_kind(kind, get("#{kind}_type"))
    end

    # Sceglie la tipologia e ne imposta le dimensioni predefinite.
    def apply_opening_type(kind, id)
      t = OpeningTypes.for_kind(kind, id)
      set("#{kind}_type", t['id'])
      set("#{kind}_width", (t['width'] * 1000).round)
      set("#{kind}_height", (t['height'] * 1000).round)
      set('window_sill', (t['sill'] * 1000).round) if kind == 'window'
      t
    end

    def edit
      fields = [
        ['wall_thickness', 'Muro: spessore (mm)'],
        ['wall_height', 'Muro: altezza (mm, 0 = altezza del livello)'],
        ['slab_thickness', 'Solaio: spessore (mm, senza tipologia)'],
        ['column_width', 'Pilastro: larghezza (mm)'],
        ['column_depth', 'Pilastro: profondità (mm)'],
        ['beam_width', 'Trave: larghezza (mm)'],
        ['beam_height', 'Trave: altezza (mm)'],
        ['stair_width', 'Scala: larghezza (mm)'],
        ['stair_riser', 'Scala: alzata massima (mm)'],
        ['door_width', 'Porta: larghezza (mm)'],
        ['door_height', 'Porta: altezza (mm)'],
        ['window_width', 'Finestra: larghezza (mm)'],
        ['window_height', 'Finestra: altezza (mm)'],
        ['window_sill', 'Finestra: altezza davanzale (mm)']
      ]
      none = '(nessuna: spessore libero)'
      types = WallTypeLibrary.all(Sketchup.active_model)
      slab_types = WallTypeLibrary.all(Sketchup.active_model, kind: 'slab')
      current = WallTypes.find(types, get('wall_type'))
      current_slab = WallTypes.find(slab_types, get('slab_type'))
      doors = OpeningTypes.all('door')
      windows = OpeningTypes.all('window')
      prompts = ['Muro: tipologia (stratigrafia)', 'Muro: allineamento', 'Solaio: tipologia (stratigrafia)',
                 'Porta: tipologia', 'Finestra: tipologia'] + fields.map(&:last)
      defaults = [current ? current['name'] : none, ALIGN_LABELS[get('wall_align')] || 'Asse',
                  current_slab ? current_slab['name'] : none, opening_type('door')['name'],
                  opening_type('window')['name']] + fields.map { |k, _| get(k).to_s }
      lists = [([none] + types.map { |t| t['name'] }).join('|'), ALIGN_LABELS.values.join('|'),
               ([none] + slab_types.map { |t| t['name'] }).join('|'), doors.map { |t| t['name'] }.join('|'),
               windows.map { |t| t['name'] }.join('|')] + Array.new(fields.size, '')
      result = UI.inputbox(prompts, defaults, lists, 'BIMSketch - Impostazioni elementi')
      return false unless result

      chosen = types.find { |t| t['name'] == result.shift }
      set('wall_type', chosen ? chosen['id'] : '')
      set('wall_align', ALIGN_LABELS.key(result.shift) || 'center')
      chosen_slab = slab_types.find { |t| t['name'] == result.shift }
      set('slab_type', chosen_slab ? chosen_slab['id'] : '')
      chosen_openings = { 'door' => doors.find { |t| t['name'] == result.shift },
                          'window' => windows.find { |t| t['name'] == result.shift } }
      before = fields.map { |k, _| get(k).to_s }
      fields.each_with_index do |(key, _), i|
        v = result[i].to_s.tr(',', '.').to_f
        min = key == 'wall_height' || key == 'window_sill' ? 0 : 1
        set(key, v.round(1)) if v >= min
      end
      # Una tipologia appena scelta porta le sue dimensioni, salvo che siano
      # state cambiate a mano nella stessa finestra.
      chosen_openings.each do |kind, t|
        next unless t && t['id'] != opening_type(kind)['id']

        keys = fields.map(&:first).each_index.select { |i| fields[i][0].start_with?(kind) }
        if keys.all? { |i| result[i].to_s == before[i] }
          apply_opening_type(kind, t['id'])
        else
          set("#{kind}_type", t['id'])
        end
      end
      true
    end
  end
end
