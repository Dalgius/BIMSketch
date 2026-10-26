# frozen_string_literal: true

module BIMSketch
  module Tools
    # Strumento Porta/Finestra: si passa sopra un muro creato con BIMSketch e
    # si clicca per inserire l'apertura (il foro viene tagliato nel muro).
    class OpeningTool < BaseTool
      def initialize(kind)
        super()
        @kind = kind # 'door' o 'window'
      end

      def enableVCB?
        false
      end

      def onMouseMove(flags, x, y, view)
        @wall = nil
        @local_x = nil
        ph = view.pick_helper
        ph.do_pick(x, y)
        candidate = ph.best_picked
        if candidate && Builder.parametric_wall?(candidate)
          @ip.pick(view, x, y)
          if @ip.valid?
            @wall = candidate
            @local_x = to_wall_local(@ip.position).x
          end
        end
        # In pianta il taglio della sezione non si seleziona: si cerca il muro
        # lungo la linea di vista.
        unless @wall
          hit = Builder.wall_under_ray(model, view.pickray(x, y))
          if hit
            @wall = hit[0]
            @local_x = to_wall_local(hit[1]).x
          end
        end
        super(flags, x, y, view) unless @wall
        update_preview(view)
        update_ui
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, view)
        unless @wall
          UI.beep
          return
        end
        if rect.nil?
          UI.messagebox("L'apertura non entra nel muro o si sovrappone a un'altra apertura: " \
                        'verifica posizione e dimensioni nelle impostazioni.')
          return
        end
        wall = @wall
        local_x = @local_x
        label = door? ? 'Porta' : 'Finestra'
        run_operation("BIMSketch: #{label}") do
          Builder.opening(model, wall, @kind, local_x, width, height, sill, type_id: type['id'])
        end
        @wall = nil
        @preview = []
        view.invalidate
      end

      def draw(view)
        draw_preview(view)
      end

      # Tasto destro: scelta della tipologia (con le sue dimensioni predefinite).
      def getMenu(menu, *args)
        sub = menu.add_submenu(door? ? 'Tipologia porta' : 'Tipologia finestra')
        OpeningTypes.all(@kind).each do |t|
          dims = format('%d x %d cm', (t['width'] * 100).round, (t['height'] * 100).round)
          item = sub.add_item("#{t['name']} (#{dims})") do
            Settings.apply_opening_type(@kind, t['id'])
            update_ui
            Sketchup.active_model.active_view.invalidate
          end
          sub.set_validation_proc(item) { t['id'] == type['id'] ? MF_CHECKED : MF_UNCHECKED }
        end
        super
      end

      protected

      def door?
        @kind == 'door'
      end

      def type
        Settings.opening_type(@kind)
      end

      def width
        Settings.length(door? ? 'door_width' : 'window_width')
      end

      def height
        Settings.length(door? ? 'door_height' : 'window_height')
      end

      def sill
        door? ? 0 : Settings.length('window_sill')
      end

      def update_ui
        what = type['name']
        dims = "#{width.to_s} x #{height.to_s}"
        Sketchup.status_text = if @wall
                                 "#{what} #{dims}: clic per inserire nel muro."
                               else
                                 "#{what} #{dims}: passa sopra un muro BIMSketch. " \
                                   'Tasto destro: tipologia e impostazioni.'
                               end
      end

      # Trasformazione contesto attivo -> mondo.
      def context_tr
        model.active_path ? model.edit_transform : Geom::Transformation.new
      end

      def to_wall_local(world_point)
        world_point.transform((context_tr * @wall.transformation).inverse)
      end

      def rect
        return nil unless @wall && @local_x

        Builder.opening_rect(@wall, @local_x, width, height, sill)
      end

      def update_preview(_view)
        @preview = []
        r = rect
        return unless r

        a, b, c, d = r
        t = @wall.definition.bounds.max.y
        tr = context_tr * @wall.transformation
        @preview = [0, t].map do |y|
          [[a, y, c], [b, y, c], [b, y, d], [a, y, d]].map { |p| Geom::Point3d.new(p).transform(tr) }
        end
      end
    end
  end
end
