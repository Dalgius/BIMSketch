# frozen_string_literal: true

module BIMSketch
  # Helper per la codifica dei valori nel formato STEP (ISO 10303-21).
  module Step
    UNSET = '$'
    DERIVED = '*'

    module_function

    # Stringa STEP con escape di apici, backslash e caratteri non ASCII
    # (codificati con le direttive \X2\ ... \X0\ e \X4\ ... \X0\).
    def str(value)
      return UNSET if value.nil?

      out = +"'"
      wide = []
      flush = lambda do
        next if wide.empty?

        if wide.any? { |cp| cp > 0xFFFF }
          out << '\\X4\\' << wide.map { |cp| format('%08X', cp) }.join << '\\X0\\'
        else
          out << '\\X2\\' << wide.map { |cp| format('%04X', cp) }.join << '\\X0\\'
        end
        wide.clear
      end
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).each_char do |ch|
        cp = ch.ord
        if cp >= 32 && cp <= 126
          flush.call
          out << (ch == "'" ? "''" : ch == '\\' ? '\\\\' : ch)
        else
          wide << cp
        end
      end
      flush.call
      out << "'"
    end

    # Numero reale: notazione STEP con punto decimale obbligatorio.
    def real(value)
      v = value.to_f
      v = 0.0 if v.abs < 1e-12 || !v.finite?
      s = format('%.6f', v)
      s = s.sub(/0+\z/, '')
      s == '-0.' ? '0.' : s
    end

    def int(value)
      Integer(value).to_s
    end

    def enum(value)
      value.nil? ? UNSET : ".#{value.to_s.upcase}."
    end

    def bool(value)
      value ? '.T.' : '.F.'
    end

    def ref(id)
      id.nil? ? UNSET : "##{id}"
    end

    def list(items)
      "(#{items.join(',')})"
    end

    def refs(ids)
      list(ids.map { |i| ref(i) })
    end

    # Valore tipizzato, es. typed('IFCLABEL', str('abc')) -> IFCLABEL('abc')
    def typed(type, encoded)
      "#{type}(#{encoded})"
    end
  end
end
