# frozen_string_literal: true

module BIMSketch
  # Impostazioni utente persistenti (valori in millimetri).
  module Settings
    SECTION = 'BIMSketch'

    DEFAULTS = {
      'wall_thickness' => 300, 'wall_height' => 0, 'wall_align' => 'center', 'wall_type' => '',
      'slab_thickness' => 250,
      'column_width' => 300, 'column_depth' => 300,
      'beam_width' => 300, 'beam_height' => 500,
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

    def edit
      fields = [
        ['wall_thickness', 'Muro: spessore (mm)'],
        ['wall_height', 'Muro: altezza (mm, 0 = altezza del livello)'],
        ['slab_thickness', 'Solaio: spessore (mm)'],
        ['column_width', 'Pilastro: larghezza (mm)'],
        ['column_depth', 'Pilastro: profondità (mm)'],
        ['beam_width', 'Trave: larghezza (mm)'],
        ['beam_height', 'Trave: altezza (mm)'],
        ['door_width', 'Porta: larghezza (mm)'],
        ['door_height', 'Porta: altezza (mm)'],
        ['window_width', 'Finestra: larghezza (mm)'],
        ['window_height', 'Finestra: altezza (mm)'],
        ['window_sill', 'Finestra: altezza davanzale (mm)']
      ]
      none = '(nessuna: spessore libero)'
      types = WallTypeLibrary.all(Sketchup.active_model)
      current = WallTypes.find(types, get('wall_type'))
      prompts = ['Muro: tipologia (stratigrafia)', 'Muro: allineamento'] + fields.map(&:last)
      defaults = [current ? current['name'] : none, ALIGN_LABELS[get('wall_align')] || 'Asse'] +
                 fields.map { |k, _| get(k).to_s }
      lists = [([none] + types.map { |t| t['name'] }).join('|'), ALIGN_LABELS.values.join('|')] +
              Array.new(fields.size, '')
      result = UI.inputbox(prompts, defaults, lists, 'BIMSketch - Impostazioni elementi')
      return false unless result

      chosen = types.find { |t| t['name'] == result.shift }
      set('wall_type', chosen ? chosen['id'] : '')
      set('wall_align', ALIGN_LABELS.key(result.shift) || 'center')
      fields.each_with_index do |(key, _), i|
        v = result[i].to_s.tr(',', '.').to_f
        min = key == 'wall_height' || key == 'window_sill' ? 0 : 1
        set(key, v.round(1)) if v >= min
      end
      true
    end
  end
end
