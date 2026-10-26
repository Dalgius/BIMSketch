# frozen_string_literal: true

require 'json'

module BIMSketch
  # Finestre di dialogo HTML (UI::HtmlDialog) dell'estensione.
  module Dialogs
    HTML_DIR = File.join(__dir__, 'html')

    # Base comune: crea il dialog al primo utilizzo, registra le callback
    # JavaScript -> Ruby e invia dati alla pagina tramite BIM.<funzione>(json).
    class Base
      def initialize(title, file, width, height)
        @title = title
        @file = file
        @width = width
        @height = height
      end

      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return
        end
        @dialog = ::UI::HtmlDialog.new(
          dialog_title: @title, preferences_key: "BIMSketch_#{@file}",
          scrollable: true, resizable: true, width: @width, height: @height,
          min_width: 320, min_height: 240, style: ::UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.set_file(File.join(HTML_DIR, "#{@file}.html"))
        @dialog.add_action_callback('ready') { |_ctx, *_args| safe { refresh } }
        callbacks.each do |name, handler|
          @dialog.add_action_callback(name) do |_ctx, payload = nil|
            safe { handler.call(parse(payload)) }
          end
        end
        @dialog.set_on_closed { on_closed } if @dialog.respond_to?(:set_on_closed)
        on_open
        @dialog.show
      end

      def visible?
        @dialog && @dialog.visible?
      end

      def refresh; end

      protected

      def callbacks
        {}
      end

      def on_open; end

      def on_closed; end

      def model
        Sketchup.active_model
      end

      def push(function, data)
        return unless @dialog

        @dialog.execute_script("BIM.#{function}(#{JSON.generate(data)})")
      end

      def parse(payload)
        return {} if payload.nil? || payload == ''

        payload.is_a?(String) ? JSON.parse(payload) : payload
      rescue JSON::ParserError
        {}
      end

      def safe
        yield
      rescue StandardError => e
        puts "BIMSketch: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
        push('error', e.message)
      end

      def types_payload
        ElementTypes.all.map { |t| ElementTypes.to_h(t) }
      end

      def levels_payload
        Levels.all(model).map { |l| { 'id' => l['id'], 'name' => l['name'] } }
      end
    end

    # Osservatore della selezione con aggiornamento differito.
    class SelectionWatcher < Sketchup::SelectionObserver
      def initialize(&block)
        super()
        @block = block
        @pending = false
      end

      def trigger
        return if @pending

        @pending = true
        ::UI.start_timer(0.15, false) do
          @pending = false
          @block.call
        end
      end

      def onSelectionBulkChange(_sel)
        trigger
      end

      def onSelectionCleared(_sel)
        trigger
      end

      def onSelectionAdded(_sel, _ent)
        trigger
      end

      def onSelectionRemoved(_sel, _ent)
        trigger
      end
    end

    # Pannello Proprietà BIM: mostra e modifica i dati della selezione.
    class Properties < Base
      def initialize
        super('BIMSketch - Proprietà BIM', 'properties', 420, 680)
      end

      def refresh
        sel = model.selection
        elements = sel.select { |e| BimData.element?(e) }
        others = sel.count { |e| !BimData.element?(e) }
        data = { 'types' => types_payload, 'levels' => levels_payload,
                 'count' => elements.size, 'unclassified' => others }
        if elements.size == 1
          data['mode'] = 'single'
          data['element'] = element_payload(elements.first)
        elsif elements.size > 1
          data['mode'] = 'multi'
          keys = elements.map { |e| BimData.type_key(e) }.uniq
          data['common_type'] = keys.size == 1 ? keys.first : nil
          data['dims'] = elements.any? { |e| Builder.element_height(model, e) }
          data['wall_types'] = wall_types_payload if elements.any? { |e| Builder.parametric_wall?(e) }
          data['slab_types'] = wall_types_payload('slab') if elements.any? { |e| Builder.parametric_slab?(e) }
          kinds = elements.map { |e| BimData.type_key(e) }.uniq
          if kinds.size == 1 && %w[door window].include?(kinds.first)
            data['opening_types'] = opening_types_payload(kinds.first)
          end
          data['summary'] = elements.group_by { |e| BimData.type(e) }.map do |t, es|
            { 'label' => t ? t.plural : '?', 'count' => es.size }
          end
        else
          data['mode'] = 'none'
        end
        push('render', data)
      end

      protected

      def callbacks
        {
          'save' => ->(d) { save(d) },
          'classify' => lambda { |d|
            Commands.classify_selection(d['type'])
            refresh
          },
          'declassify' => lambda { |_d|
            Commands.declassify_selection
            refresh
          },
          'refresh' => ->(_d) { refresh },
          'levels' => ->(_d) { BIMSketch.levels_dialog.show },
          'wall_types' => ->(d) { BIMSketch.wall_types_dialog.show_kind(d['kind'] || 'wall') }
        }
      end

      def on_open
        @model = model
        @watcher = SelectionWatcher.new { refresh if visible? }
        @model.selection.add_observer(@watcher)
      end

      def on_closed
        @model.selection.remove_observer(@watcher) if @model && @watcher && @model.valid?
        @watcher = nil
      end

      def element_payload(entity)
        data = BimData.read(entity)
        ctx = model.active_path ? model.edit_transform : Geom::Transformation.new
        rec = Collector.record(model, entity, ctx * entity.transformation, false)
        data['quantities'] = Records.quantities(rec).map do |q|
          { 'label' => q[:label], 'name' => q[:name],
            'value' => Quantities.format_number(q[:value], q[:kind] == :length ? 3 : 2),
            'unit' => Quantities::UNITS[q[:kind]] }
        end
        data['solid'] = rec[:solid]
        info = Builder.element_height(model, entity)
        data['dims'] = { 'height' => info[:height].to_m.round(4), 'auto' => info[:auto] } if info
        if Builder.parametric_wall?(entity)
          g = Builder.wall_geom(entity)
          type = Builder.wall_type(model, entity)
          external = BimData.json_attr(entity, 'props')['IsExternal'] == true
          data['wall'] = {
            'type_id' => type ? type['id'] : '', 'flipped' => g ? g[:flipped] : false,
            'types' => wall_types_payload,
            'layers' => type ? type['layers'] : [],
            'u' => type ? WallTypes.u_value(type, external: external) : nil,
            'thickness' => g ? (g[:thickness].to_m * 100).round(2) : nil
          }
        end
        if Builder.parametric_slab?(entity)
          g = Builder.slab_geom(entity)
          type = Builder.slab_type(model, entity)
          external = BimData.json_attr(entity, 'props')['IsExternal'] == true
          sz = Geometry.scales(entity.transformation)[2]
          data['slab'] = {
            'type_id' => type ? type['id'] : '', 'types' => wall_types_payload('slab'),
            'layers' => type ? type['layers'] : [],
            'u' => type && WallTypes.u_value(type, external: external,
                                                   flow: WallTypes.flow_for(BimData.type_key(entity))),
            'thickness' => (g[:thickness] * sz).to_m * 100
          }
        end
        if %w[door window].include?(BimData.type_key(entity)) && Builder.host_wall(model, entity)
          data['opening'] = { 'type_id' => entity.get_attribute(BimData::DICT, 'opening_type').to_s,
                              'types' => opening_types_payload(BimData.type_key(entity)) }
        end
        data['sketchup_material'] = entity.material ? entity.material.display_name : ''
        data
      end

      # Applica altezza numerica o automatica (campi 'height' in m e
      # 'auto_height'). Restituisce false se l'elemento non è stato adattato.
      def apply_height(entity, el)
        info = Builder.element_height(model, entity)
        return true unless info && el.key?('auto_height')

        auto = case el['auto_height']
               when true, 'true' then true
               when false, 'false' then false
               end
        height = begin
          Float(el['height'].to_s.strip.tr(',', '.')).m
        rescue ArgumentError, TypeError
          nil
        end
        if auto
          lvl = Levels.find(model, BimData.level_id(entity)) || Levels.for_entity(model, entity)
          return true if info[:auto] && (info[:height] - lvl['height'].m).abs < 0.5.mm

          return Builder.set_height(model, entity, auto: true)
        end
        target = height || (auto == false ? info[:height] : nil)
        return true unless target
        return true if (target - info[:height]).abs < 0.5.mm && !(auto == false && info[:auto])

        Builder.set_height(model, entity, height: target, auto: false)
      end

      def opening_types_payload(kind)
        OpeningTypes.all(kind).map do |t|
          dims = format('%d x %d cm', (t['width'] * 100).round, (t['height'] * 100).round)
          dims += format(', davanzale %d cm', (t['sill'] * 100).round) if t['sill'].positive?
          { 'id' => t['id'], 'name' => "#{t['name']} (#{dims})" }
        end
      end

      # Tipologia di porta o finestra (campo 'opening_type_id').
      def apply_opening_type(entity, el)
        id = el['opening_type_id'].to_s
        return true unless %w[door window].include?(BimData.type_key(entity))
        return true if id.empty? || id == '(invariato)' || id == entity.get_attribute(BimData::DICT, 'opening_type')

        Builder.change_opening_type(model, entity, id)
      end

      def wall_types_payload(kind = 'wall')
        WallTypeLibrary.all(model, kind: kind).map do |t|
          { 'id' => t['id'], 'name' => t['name'], 'summary' => WallTypes.summary(t) }
        end
      end

      # Tipologia e verso degli strati (campi 'wall_type_id' e 'wall_flipped');
      # ricalcola comunque la trasmittanza (può cambiare con "Esterno").
      def apply_wall_type(entity, el)
        return true unless Builder.parametric_wall?(entity)

        ok = true
        g = Builder.wall_geom(entity)
        if el.key?('wall_type_id') && !el['wall_type_id'].nil? && g
          id = el['wall_type_id'].to_s
          flipped = case el['wall_flipped']
                    when true, 'true' then true
                    when false, 'false' then false
                    else g[:flipped]
                    end
          unless id == '(invariato)' || (id == g[:type_id].to_s && flipped == g[:flipped])
            ok = Builder.apply_wall_type(model, entity, id.empty? ? nil : id, flipped: flipped)
          end
        end
        type = Builder.wall_type(model, entity)
        Builder.apply_type_data(model, entity, type) if type
        ok
      end

      # Tipologia di solaio (campo 'slab_type_id'); ricalcola la trasmittanza.
      def apply_slab_type(entity, el)
        return true unless Builder.parametric_slab?(entity)

        ok = true
        id = el['slab_type_id']
        unless id.nil? || id == '(invariato)' || id.to_s == Builder.slab_geom_type_id(entity).to_s
          ok = Builder.apply_slab_type(model, entity, id.to_s.empty? ? nil : id.to_s)
        end
        type = Builder.slab_type(model, entity)
        Builder.apply_slab_type_data(model, entity, type) if type
        ok
      end

      # Livello scelto nel pannello: gli elementi che cambiano livello si
      # spostano alla quota del nuovo livello (vedi Levels.relocate).
      # Restituisce il numero di elementi la cui altezza non è stata adattata.
      def change_level(elements, id)
        return 0 if id.to_s.empty?

        moving = elements.reject { |e| BimData.level_id(e) == id }
        moving.empty? ? 0 : Levels.relocate(model, moving, id)
      end

      def save(data)
        elements = model.selection.select { |e| BimData.element?(e) }
        return if elements.empty?

        failed = 0
        model.start_operation('BIMSketch: Proprietà', true)
        if data['mode'] == 'single'
          el = data['element'] || {}
          BimData.write(elements.first, el.reject { |k, _| k == 'level' })
          # "(automatico)": il livello verrà dedotto dalla quota.
          elements.first.set_attribute(BimData::DICT, 'level', '') if el.key?('level') && el['level'].to_s.empty?
          failed += change_level(elements, el['level'])
          failed += 1 unless apply_height(elements.first, data['element'] || {})
          failed += 1 unless apply_wall_type(elements.first, data['element'] || {})
          failed += 1 unless apply_slab_type(elements.first, data['element'] || {})
          failed += 1 unless apply_opening_type(elements.first, data['element'] || {})
        else
          changes = data['element'] || {}
          elements.each do |e|
            patch = {}
            %w[type material object_type predefined].each do |k|
              patch[k] = changes[k] unless changes[k].to_s.empty?
            end
            props = (changes['props'] || {}).reject { |_, v| v.to_s.empty? }
            patch['props'] = BimData.json_attr(e, 'props').merge(props) unless props.empty?
            BimData.write(e, patch)
            failed += 1 unless apply_height(e, changes)
            failed += 1 unless apply_wall_type(e, changes)
            failed += 1 unless apply_slab_type(e, changes)
            failed += 1 unless apply_opening_type(e, changes)
          end
          failed += change_level(elements, changes['level'])
        end
        model.commit_operation
        refresh
        push('saved', true)
        if failed.positive?
          ::UI.messagebox("#{failed} modifiche di altezza o tipologia non applicate: gli elementi sono stati " \
                          'modificati a mano oppure le aperture non entrerebbero nel muro.')
        end
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # Gestione livelli (piani dell'edificio).
    class LevelsManager < Base
      def initialize
        super('BIMSketch - Livelli', 'levels', 560, 460)
      end

      def refresh
        levels = Levels.all(model)
        counts = Hash.new(0)
        model.entities.each { |e| counts[BimData.level_id(e)] += 1 if BimData.element?(e) }
        push('render', 'levels' => levels.map { |l| l.merge('count' => counts[l['id']]) },
                       'current' => Levels.current_id(model))
      end

      protected

      def callbacks
        {
          'save' => lambda { |d|
            Levels.update(model, d['levels'], move_elements: d['move'] != false)
            refresh
            n = Levels.skipped_last_update
            if n.positive?
              ::UI.messagebox("#{n} muri/pilastri non hanno preso la nuova altezza del livello: sono stati " \
                              'modificati a mano oppure le loro aperture non entrerebbero.')
            end
          },
          'add' => lambda { |d|
            levels = Levels.all(model)
            levels = LevelList.normalize(d['levels']) if d['levels']
            model.start_operation('BIMSketch: Nuovo livello', true)
            Levels.save(model, levels + [LevelList.build_next(levels)])
            model.commit_operation
            refresh
          },
          'delete' => lambda { |d|
            levels = Levels.all(model).reject { |l| l['id'] == d['id'] }
            if levels.empty?
              ::UI.messagebox('Deve esistere almeno un livello.')
            else
              model.start_operation('BIMSketch: Elimina livello', true)
              Levels.save(model, levels)
              model.commit_operation
            end
            refresh
          },
          'set_current' => lambda { |d|
            model.start_operation('BIMSketch: Livello corrente', true, false, true)
            Levels.set_current(model, d['id'])
            model.commit_operation
            refresh
          },
          'select' => lambda { |d|
            model.selection.clear
            model.selection.add(Levels.elements_on(model, d['id']))
          },
          'isolate' => ->(d) { Levels.isolate(model, d['id']) },
          'show_all' => ->(_d) { Levels.isolate(model, nil) },
          'plan_view' => ->(d) { Levels.create_plan_view(model, d['id']) },
          'assign' => lambda { |d|
            n = Commands.assign_selection_to_level(d['id'])
            ::UI.messagebox('Seleziona prima uno o più elementi BIM.') if n.to_i.zero?
            refresh
          }
        }
      end
    end

    # Librerie delle tipologie (stratigrafie) di muri e solai, una scheda per tipo.
    class WallTypesManager < Base
      KIND_LABELS = { 'wall' => %w[muro muri], 'slab' => %w[solaio solai] }.freeze

      def initialize
        super('BIMSketch - Stratigrafie', 'wall_types', 820, 560)
        @kind = 'wall'
      end

      # Apre il dialog sulla scheda indicata ('wall' o 'slab').
      def show_kind(kind)
        @kind = KIND_LABELS.key?(kind) ? kind : 'wall'
        refresh if visible?
        show
      end

      def refresh
        types = WallTypeLibrary.all(model, kind: @kind)
        usage = Hash.new(0)
        model.active_entities.each do |e|
          id = type_id_of(e)
          usage[id] += 1 if id
        end
        selected = model.selection.count { |e| target?(e) }
        rsi = WallTypes::RSI_BY_FLOW[@kind == 'slab' ? :down : :horizontal]
        push('render', 'kind' => @kind, 'types' => types, 'usage' => usage, 'selected' => selected,
                       'functions' => WallTypes::FUNCTIONS, 'rsi' => rsi, 'rse' => WallTypes::RSE)
      end

      protected

      def callbacks
        {
          'save' => ->(d) { save(d['types']) },
          'assign' => ->(d) { assign(d['id'], d['flipped'] == true) },
          'kind' => lambda { |d|
            @kind = KIND_LABELS.key?(d['kind']) ? d['kind'] : 'wall'
            refresh
          },
          'refresh' => ->(_d) { refresh }
        }
      end

      def target?(entity)
        @kind == 'slab' ? Builder.parametric_slab?(entity) : Builder.parametric_wall?(entity)
      end

      def type_id_of(entity)
        if @kind == 'slab'
          Builder.slab_geom_type_id(entity)
        elsif Builder.parametric_wall?(entity)
          g = Builder.wall_geom(entity)
          g && g[:type_id]
        end
      end

      def update_elements(id, remove: false)
        if @kind == 'slab'
          Builder.update_type_slabs(model, id, remove: remove)
        else
          Builder.update_type_walls(model, id, remove: remove)
        end
      end

      def save(types)
        old = WallTypeLibrary.all(model, kind: @kind)
        model.start_operation('BIMSketch: Stratigrafie', true)
        list = WallTypeLibrary.save(model, types, kind: @kind)
        failed = 0
        list.each do |t|
          before = WallTypes.find(old, t['id'])
          next if before.nil? || JSON.generate(before) == JSON.generate(t)

          failed += update_elements(t['id'])
        end
        (old.map { |t| t['id'] } - list.map { |t| t['id'] }).each do |id|
          failed += update_elements(id, remove: true)
        end
        model.commit_operation
        refresh
        push('saved', true)
        report(failed)
      rescue StandardError
        model.abort_operation
        raise
      end

      def assign(id, flipped)
        items = model.selection.select { |e| target?(e) }
        if items.empty?
          what = @kind == 'slab' ? 'solai o coperture' : 'muri'
          ::UI.messagebox("Seleziona uno o più #{what} BIMSketch.")
          return
        end
        model.start_operation('BIMSketch: Assegna tipologia', true)
        failed = items.count do |e|
          if @kind == 'slab'
            !Builder.apply_slab_type(model, e, id)
          else
            !Builder.apply_wall_type(model, e, id, flipped: flipped)
          end
        end
        model.commit_operation
        refresh
        report(failed)
      rescue StandardError
        model.abort_operation
        raise
      end

      def report(failed)
        return unless failed.positive?

        what = KIND_LABELS[@kind][1]
        reason = 'sono stati modificati a mano'
        reason += ' oppure le loro aperture non entrerebbero' unless @kind == 'slab'
        ::UI.messagebox("#{failed} #{what} non sono stati aggiornati: #{reason}.")
      end
    end

    # Abaco delle quantità.
    class Schedule < Base
      def initialize
        super('BIMSketch - Abaco quantità', 'schedule', 980, 560)
      end

      def refresh
        records = Collector.collect(model)
        rows = Records.schedule_rows(records, Levels.all(model))
        push('render', 'rows' => rows, 'totals' => Records.totals(rows),
                       'levels' => levels_payload, 'takeoff' => Records.material_takeoff(records))
      end

      protected

      def callbacks
        {
          'select' => ->(d) { Commands.select_guids(Array(d['guids'])) },
          'export_csv' => ->(_d) { Commands.export_schedule_csv },
          'export_takeoff' => ->(_d) { Commands.export_takeoff_csv },
          'refresh' => ->(_d) { refresh }
        }
      end
    end

    # Verifica del modello.
    class Checker < Base
      def initialize
        super('BIMSketch - Verifica modello', 'checker', 600, 520)
      end

      def refresh
        records = Collector.collect(model)
        groups, faces = Collector.unclassified_stats(model)
        issues = BIMSketch::Checker.analyze(records, Levels.all(model),
                                            unclassified_count: groups, loose_faces: faces)
        push('render', 'issues' => issues.map { |i| i.transform_keys(&:to_s) },
                       'count' => records.size)
      end

      protected

      def callbacks
        {
          'select' => ->(d) { Commands.select_guids(Array(d['guids'])) },
          'fix_guids' => lambda { |_d|
            Commands.fix_duplicate_guids
            refresh
          },
          'assign_levels' => lambda { |_d|
            n = Commands.assign_missing_levels
            ::UI.messagebox("Livello assegnato a #{n} elementi.")
            refresh
          },
          'refresh' => ->(_d) { refresh }
        }
      end
    end
  end
end
