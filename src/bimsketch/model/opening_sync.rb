# frozen_string_literal: true

require 'json'

module BIMSketch
  # Tiene allineate porte e finestre ai loro muri quando vengono spostate
  # con gli strumenti di SketchUp (Sposta, Ruota, copia con Ctrl):
  # - apertura spostata lungo il muro: il foro viene ritagliato nella nuova
  #   posizione (in verticale cambia il davanzale delle finestre);
  # - posizione non valida o lontana dal muro: l'apertura torna al suo posto;
  # - copia di un'apertura: diventa una nuova apertura con un nuovo GlobalId,
  #   oppure viene eliminata se non entra nel muro;
  # - muro spostato da solo: l'apertura lo segue.
  # Le correzioni avvengono in un'operazione trasparente, unita a quella
  # dell'utente (un solo Annulla).
  module OpeningSync
    FAR = 1.0 # m: oltre questa distanza dal piano del muro l'apertura torna indietro

    module_function

    # Porte e finestre del contesto attivo che non sono più dove le ha messe
    # BIMSketch rispetto al loro muro.
    def candidates(model)
      model.active_entities.select do |e|
        next false unless BimData.element?(e) && %w[door window].include?(BimData.type_key(e))
        next false unless Builder.stored_rect(e)

        wall = Builder.host_wall(model, e)
        wall && !Builder.opening_in_place?(wall, e)
      end
    end

    # Sistema le aperture indicate (va chiamato dentro un'operazione).
    # Restituisce i messaggi per l'utente.
    def process(model, openings = candidates(model))
      messages = []
      openings.each do |o|
        next unless o.valid?

        wall = Builder.host_wall(model, o)
        next unless wall

        msg = sync(model, o, wall)
        messages << msg if msg
      end
      messages.uniq
    end

    def sync(model, opening, wall)
      rect = Builder.stored_rect(opening)
      kind = BimData.type_key(opening)
      type = OpeningTypes.for_kind(kind, opening.get_attribute(BimData::DICT, 'opening_type'))
      registered = Builder.wall_openings(wall).any? { |r| Builder.same_rect?(r, rect) }
      copy = copy?(model, opening)
      what = kind == 'door' ? 'La porta' : 'La finestra'

      # L'apertura non è stata toccata: è cambiato il muro (spostato o ricostruito).
      if !copy && placed_unchanged?(opening)
        Builder.place_opening(model, opening, wall, kind, rect, type) if registered
        return nil
      end
      return nil unless copy || registered

      target = target_rect(wall, opening, kind, rect, copy)
      unless target && Builder.wall_intact?(wall)
        if copy
          opening.erase!
          return "#{what} copiata non entra in quel punto del muro ed è stata eliminata. " \
                 'Per aggiungere aperture usa gli strumenti Porta e Finestra.'
        end
        Builder.place_opening(model, opening, wall, kind, rect, type)
        return "#{what} non entra in quella posizione (fuori dal muro o sovrapposta a un'altra apertura): " \
               'è tornata al suo posto.'
      end

      openings = Builder.wall_openings(wall)
      if copy
        BimData.regenerate_guid(opening)
        openings += [target]
      else
        openings = openings.map { |r| Builder.same_rect?(r, rect) ? target : r }
      end
      Builder.rebuild_wall_openings(model, wall, openings)
      Builder.place_opening(model, opening, wall, kind, target, type)
      nil
    end

    # Vano corrispondente alla posizione attuale dell'apertura (stessa
    # larghezza e altezza), o nil se è lontana dal muro o non entra.
    def target_rect(wall, opening, kind, rect, copy)
      sx, sy, sz = Geometry.scales(wall.transformation)
      local = wall.transformation.inverse * opening.transformation
      origin = Geom::Point3d.new(0, 0, 0).transform(local)
      expected, = Builder.opening_frame(wall, kind, rect)
      expected_y = Geom::Point3d.new(0, 0, 0).transform(wall.transformation.inverse * expected).y
      return nil if (origin.y - expected_y).abs * sy > FAR.m

      a = origin.x.to_f
      c = kind == 'door' ? 0.0 : origin.z.to_f
      w = rect[1] - rect[0]
      h = rect[3] - rect[2]
      target = Builder.opening_rect(wall, a + w / 2.0, w * sx, h * sz, c * sz, ignore: copy ? nil : rect)
      return nil unless target
      return nil if (target[0] - a).abs * sx > 1.mm || (target[2] - c).abs * sz > 1.mm

      target
    end

    def placed_unchanged?(opening)
      raw = opening.get_attribute(BimData::DICT, 'placed_tr')
      raw && Builder.same_transform?(Geom::Transformation.new(JSON.parse(raw)), opening.transformation)
    rescue JSON::ParserError
      false
    end

    # Copia: un'altra apertura con lo stesso GlobalId è ancora al suo posto.
    def copy?(model, opening)
      guid = BimData.guid(opening)
      model.active_entities.any? do |e|
        next false if e == opening || !BimData.element?(e) || BimData.guid(e) != guid

        wall = Builder.host_wall(model, e)
        wall && Builder.opening_in_place?(wall, e)
      end
    end

    # Esegue la sincronizzazione dopo un'operazione dell'utente.
    def run(model)
      return unless model.valid?

      list = candidates(model)
      return if list.empty?

      @busy = true
      model.start_operation('BIMSketch: Aggiorna aperture', true, false, true)
      messages = process(model, list)
      model.commit_operation
      ::UI.messagebox(messages.join("\n\n")) unless messages.empty?
    rescue StandardError => e
      model.abort_operation
      puts "BIMSketch: #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
    ensure
      @busy = false
    end

    def schedule(model)
      return if @busy || @pending

      @pending = true
      ::UI.start_timer(0, false) do
        @pending = false
        run(model)
      end
    end

    # Osservatore del modello: dopo ogni operazione controlla le aperture.
    class Observer < Sketchup::ModelObserver
      def onTransactionCommit(model)
        OpeningSync.schedule(model)
      end
    end

    # Osservatore dell'applicazione: collega i modelli nuovi o aperti.
    class AppWatcher < Sketchup::AppObserver
      def onNewModel(model)
        OpeningSync.attach(model)
      end

      def onOpenModel(model)
        OpeningSync.attach(model)
      end
    end

    def attach(model)
      @observer ||= Observer.new
      @attached ||= {}.compare_by_identity
      return if @attached.key?(model)

      model.add_observer(@observer)
      @attached[model] = true
    end

    def install
      attach(Sketchup.active_model) if Sketchup.active_model
      return if @app_watcher

      @app_watcher = AppWatcher.new
      Sketchup.add_observer(@app_watcher)
    end
  end
end
