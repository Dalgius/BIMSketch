# frozen_string_literal: true

require 'securerandom'
require 'digest/md5'

module BIMSketch
  # Generazione e conversione dei GlobalId IFC (UUID compressi a 22 caratteri).
  module Guid
    CHARS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$'

    module_function

    # Nuovo GlobalId casuale.
    def generate
      compress(SecureRandom.hex(16))
    end

    # GlobalId deterministico ricavato da una stringa (stabile tra esportazioni).
    def from_seed(seed)
      compress(Digest::MD5.hexdigest(seed.to_s))
    end

    # Converte un UUID esadecimale (32 cifre, con o senza trattini) in GlobalId.
    def compress(hex)
      n = hex.to_s.delete('-').to_i(16)
      out = +''
      22.times do
        out.prepend(CHARS[n & 63])
        n >>= 6
      end
      out
    end

    # Converte un GlobalId nell'UUID esadecimale (32 cifre minuscole).
    def expand(guid)
      n = 0
      guid.each_char { |c| n = (n << 6) | CHARS.index(c) }
      format('%032x', n)
    end

    def valid?(guid)
      return false unless guid.is_a?(String) && guid.length == 22
      return false unless guid.each_char.all? { |c| CHARS.include?(c) }

      CHARS.index(guid[0]) < 4
    end
  end
end
