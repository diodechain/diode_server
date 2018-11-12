defmodule Sha3 do
  @compile {:inline, exor: 5, band: 2, rol: 2, absorb: 6, squeeze: 4}
  use Bitwise, only_operators: true

  @moduledoc """
    ExSha3 supports the three hash algorithms:
      * KECCAK1600-f the original pre-fips version as used in Ethereum
      * SHA3 the fips-202 approved final hash
      * SHAKE

    Keccak and SHA3 produce fixed length strings corresponding to their
    bit length, while shake produces an arbitary length output according
    to the provided outlen parameter.
  """
  for bit <- [224, 256, 384, 512] do
    Module.eval_quoted(
      __MODULE__,
      Code.string_to_quoted("""
        @spec keccak_#{bit}(binary()) :: binary()
        def keccak_#{bit}(source), do: keccak(#{bit}, source)

        @spec sha3_#{bit}(binary()) :: binary()
        def sha3_#{bit}(source), do: sha3(#{bit}, source)
      """)
    )
  end

  for bit <- [128, 256] do
    Module.eval_quoted(
      __MODULE__,
      Code.string_to_quoted("""
        @spec shake_#{bit}(binary(), number()) :: binary()
        def shake_#{bit}(source, outlen), do: shake(#{bit}, outlen, source)
      """)
    )
  end

  @a <<0::200*8>>
  for {bits, outlen, rate} <- [{224, 28, 144}, {256, 32, 136}, {384, 48, 104}, {512, 64, 72}] do
    defp sha3(unquote(bits), src) do
      len = byte_size(src)

      @a
      |> absorb(src, len, len, unquote(rate), <<0x06>>)
      |> binary_part(0, unquote(outlen))
    end

    defp keccak(unquote(bits), src) do
      len = byte_size(src)

      @a
      |> absorb(src, len, len, unquote(rate), <<0x01>>)
      |> binary_part(0, unquote(outlen))
    end
  end

  for {bits, rate} <- [{128, 168}, {256, 136}] do
    defp shake(unquote(bits), outlen, src) do
      len = byte_size(src)

      squeeze(
        <<0::outlen*8>>,
        absorb(@a, src, len, len, unquote(rate), <<0x1F>>),
        outlen,
        unquote(rate)
      )
    end
  end

  defp keccakf(
         <<b0::binary-size(8), b1::binary-size(8), b2::binary-size(8), b3::binary-size(8),
           b4::binary-size(8), b5::binary-size(8), b6::binary-size(8), b7::binary-size(8),
           b8::binary-size(8), b9::binary-size(8), b10::binary-size(8), b11::binary-size(8),
           b12::binary-size(8), b13::binary-size(8), b14::binary-size(8), b15::binary-size(8),
           b16::binary-size(8), b17::binary-size(8), b18::binary-size(8), b19::binary-size(8),
           b20::binary-size(8), b21::binary-size(8), b22::binary-size(8), b23::binary-size(8),
           b24::binary-size(8)>>
       ) do
    keccakf(
      b0,
      b1,
      b2,
      b3,
      b4,
      b5,
      b6,
      b7,
      b8,
      b9,
      b10,
      b11,
      b12,
      b13,
      b14,
      b15,
      b16,
      b17,
      b18,
      b19,
      b20,
      b21,
      b22,
      b23,
      b24,
      0
    )
  end

  defp keccakf(
         b0,
         b1,
         b2,
         b3,
         b4,
         b5,
         b6,
         b7,
         b8,
         b9,
         b10,
         b11,
         b12,
         b13,
         b14,
         b15,
         b16,
         b17,
         b18,
         b19,
         b20,
         b21,
         b22,
         b23,
         b24,
         24
       ) do
    <<b0::binary(), b1::binary(), b2::binary(), b3::binary(), b4::binary(), b5::binary(),
      b6::binary(), b7::binary(), b8::binary(), b9::binary(), b10::binary(), b11::binary(),
      b12::binary(), b13::binary(), b14::binary(), b15::binary(), b16::binary(), b17::binary(),
      b18::binary(), b19::binary(), b20::binary(), b21::binary(), b22::binary(), b23::binary(),
      b24::binary()>>
  end

  @full64 <<0xFFFFFFFFFFFFFFFF::little-unsigned-size(64)>>
  for {step, rc} <- [
        {0, 1},
        {1, 0x8082},
        {2, 0x800000000000808A},
        {3, 0x8000000080008000},
        {4, 0x808B},
        {5, 0x80000001},
        {6, 0x8000000080008081},
        {7, 0x8000000000008009},
        {8, 0x8A},
        {9, 0x88},
        {10, 0x80008009},
        {11, 0x8000000A},
        {12, 0x8000808B},
        {13, 0x800000000000008B},
        {14, 0x8000000000008089},
        {15, 0x8000000000008003},
        {16, 0x8000000000008002},
        {17, 0x8000000000000080},
        {18, 0x800A},
        {19, 0x800000008000000A},
        {20, 0x8000000080008081},
        {21, 0x8000000000008080},
        {22, 0x80000001},
        {23, 0x8000000080008008}
      ] do
    defp keccakf(
           b0,
           b1,
           b2,
           b3,
           b4,
           b5,
           b6,
           b7,
           b8,
           b9,
           b10,
           b11,
           b12,
           b13,
           b14,
           b15,
           b16,
           b17,
           b18,
           b19,
           b20,
           b21,
           b22,
           b23,
           b24,
           unquote(step)
         ) do
      zero = exor(b0, b5, b10, b15, b20)
      one = exor(b1, b6, b11, b16, b21)
      two = exor(b2, b7, b12, b17, b22)
      three = exor(b3, b8, b13, b18, b23)
      four = exor(b4, b9, b14, b19, b24)
      tmp0 = :crypto.exor(four, rol(one, 1))
      tmp1 = :crypto.exor(zero, rol(two, 1))
      tmp2 = :crypto.exor(one, rol(three, 1))
      tmp3 = :crypto.exor(two, rol(four, 1))
      tmp4 = :crypto.exor(three, rol(zero, 1))

      keccakf_exor(
        unquote(step),
        :crypto.exor(b0, tmp0),
        # b6 -> b1
        rol(:crypto.exor(b6, tmp1), 44),
        # b12 -> b2
        rol(:crypto.exor(b12, tmp2), 43),
        # b18 -> b3
        rol(:crypto.exor(b18, tmp3), 21),
        # b24 -> b4
        rol(:crypto.exor(b24, tmp4), 14),
        # b3 -> b5
        rol(:crypto.exor(b3, tmp3), 28),
        # b9 -> b6
        rol(:crypto.exor(b9, tmp4), 20),
        # b10 -> b7
        rol(:crypto.exor(b10, tmp0), 3),
        # b16 -> b8
        rol(:crypto.exor(b16, tmp1), 45),
        # b22 -> b9
        rol(:crypto.exor(b22, tmp2), 61),
        # b1 -> b10
        rol(:crypto.exor(b1, tmp1), 1),
        # b7 -> b11
        rol(:crypto.exor(b7, tmp2), 6),
        # b13 -> b12
        rol(:crypto.exor(b13, tmp3), 25),
        # b19 -> b13
        rol(:crypto.exor(b19, tmp4), 8),
        # b20 -> b14
        rol(:crypto.exor(b20, tmp0), 18),
        # b4 -> b15
        rol(:crypto.exor(b4, tmp4), 27),
        # b5 -> b16
        rol(:crypto.exor(b5, tmp0), 36),
        # b11 -> b17
        rol(:crypto.exor(b11, tmp1), 10),
        # b17 -> b18
        rol(:crypto.exor(b17, tmp2), 15),
        # b23 -> b19
        rol(:crypto.exor(b23, tmp3), 56),
        # b2 -> b20
        rol(:crypto.exor(b2, tmp2), 62),
        # b8 -> b21
        rol(:crypto.exor(b8, tmp3), 55),
        # b14 -> b22
        rol(:crypto.exor(b14, tmp4), 39),
        # b15 -> b23
        rol(:crypto.exor(b15, tmp0), 41),
        # b21 -> b24
        rol(:crypto.exor(b21, tmp1), 2)
      )
    end

    defp keccakf_exor(
           unquote(step),
           b0,
           b1,
           b2,
           b3,
           b4,
           b5,
           b6,
           b7,
           b8,
           b9,
           b10,
           b11,
           b12,
           b13,
           b14,
           b15,
           b16,
           b17,
           b18,
           b19,
           b20,
           b21,
           b22,
           b23,
           b24
         ) do
      # b0  -> b0 ^^^ b1 &&& b2 #0 ^^^ rc
      keccakf(
        :crypto.exor(
          :crypto.exor(b0, band(:crypto.exor(b1, @full64), b2)),
          <<unquote(rc)::little-unsigned-size(64)>>
        ),
        # b6  -> b1 ^^^ b2 &&& b3 #1
        :crypto.exor(b1, band(:crypto.exor(b2, @full64), b3)),
        # b12 -> b2 ^^^ b3 &&& b4 #2
        :crypto.exor(b2, band(:crypto.exor(b3, @full64), b4)),
        # b18 -> b3 ^^^ b4 &&& b0 #3
        :crypto.exor(b3, band(:crypto.exor(b4, @full64), b0)),
        # b24 -> b4 ^^^ b0 &&& b1 #4
        :crypto.exor(b4, band(:crypto.exor(b0, @full64), b1)),
        # b3  -> b5 ^^^ b6 &&& b7 #0
        :crypto.exor(b5, band(:crypto.exor(b6, @full64), b7)),
        # b9  -> b6 ^^^ b7 &&& b8 #1
        :crypto.exor(b6, band(:crypto.exor(b7, @full64), b8)),
        # b10 -> b7 ^^^ b8 &&& b9 #2
        :crypto.exor(b7, band(:crypto.exor(b8, @full64), b9)),
        # b16 -> b8 ^^^ b9 &&& b6 #3
        :crypto.exor(b8, band(:crypto.exor(b9, @full64), b5)),
        # b22 -> b9 ^^^ b6 &&& b5 #4
        :crypto.exor(b9, band(:crypto.exor(b5, @full64), b6)),
        # b1  -> b10 ^^^ b11 &&& b12 #0
        :crypto.exor(b10, band(:crypto.exor(b11, @full64), b12)),
        # b7  -> b11 ^^^ b12 &&& b14 #1
        :crypto.exor(b11, band(:crypto.exor(b12, @full64), b13)),
        # b13 -> b12 ^^^ b14 &&& b15 #2
        :crypto.exor(b12, band(:crypto.exor(b13, @full64), b14)),
        # b19 -> b13 ^^^ b15 &&& b10 #3
        :crypto.exor(b13, band(:crypto.exor(b14, @full64), b10)),
        # b20 -> b14 ^^^ b10 &&& b11 #4
        :crypto.exor(b14, band(:crypto.exor(b10, @full64), b11)),
        # b4  -> b15 ^^^ b16 &&& b17 #0
        :crypto.exor(b15, band(:crypto.exor(b16, @full64), b17)),
        # b5  -> b16 ^^^ b17 &&& b18 #1
        :crypto.exor(b16, band(:crypto.exor(b17, @full64), b18)),
        # b11 -> b17 ^^^ b18 &&& b19 #2
        :crypto.exor(b17, band(:crypto.exor(b18, @full64), b19)),
        # b17 -> b18 ^^^ b19 &&& b15 #3
        :crypto.exor(b18, band(:crypto.exor(b19, @full64), b15)),
        # b23 -> b19 ^^^ b15 &&& b16 #4
        :crypto.exor(b19, band(:crypto.exor(b15, @full64), b16)),
        # b2  -> b20 ^^^ b21 &&& b22 #0
        :crypto.exor(b20, band(:crypto.exor(b21, @full64), b22)),
        # b8  -> b21 ^^^ b22 &&& b23 #1
        :crypto.exor(b21, band(:crypto.exor(b22, @full64), b23)),
        # b14 -> b22 ^^^ b23 &&& b24 #2
        :crypto.exor(b22, band(:crypto.exor(b23, @full64), b24)),
        # b15 -> b23 ^^^ b24 &&& b20 #3
        :crypto.exor(b23, band(:crypto.exor(b24, @full64), b20)),
        # b21 -> b24 ^^^ b20 &&& b21 #4
        :crypto.exor(b24, band(:crypto.exor(b20, @full64), b21)),
        unquote(step) + 1
      )
    end
  end

  defp rol(<<x::little-unsigned-size(64)>>, s) do
    x = x <<< s
    y = x >>> 64
    x = (x &&& 0xFFFFFFFFFFFFFFFF) + y
    <<x::little-unsigned-size(64)>>
  end

  @zero <<0::little-unsigned-size(64)>>
  defp exor(one, two, three, four, five) do
    @zero
    |> :crypto.exor(one)
    |> :crypto.exor(two)
    |> :crypto.exor(three)
    |> :crypto.exor(four)
    |> :crypto.exor(five)
  end

  defp band(<<a::little-unsigned-size(64)>>, <<b::little-unsigned-size(64)>>) do
    <<a &&& b::little-unsigned-size(64)>>
  end

  defp xorin(dst, src, offset, len) do
    <<start::binary-size(len), rest::binary()>> = dst
    <<_start::binary-size(offset), block::binary-size(len), _rest::binary()>> = src
    <<:crypto.exor(block, start)::binary(), rest::binary()>>
  end

  defp xor(a, len, value) do
    <<start::binary-size(len), block::binary-size(1), rest::binary()>> = a
    <<start::binary(), :crypto.exor(block, value)::binary(), rest::binary()>>
  end

  # Fallbacks

  defp absorb(a, src, src_len, len, rate, delim) when len >= rate do
    a
    |> xorin(src, src_len - len, rate)
    |> keccakf()
    |> absorb(src, src_len, len - rate, rate, delim)
  end

  defp absorb(a, src, src_len, len, rate, delim) do
    a
    # Xor source the DS and pad frame.
    |> xor(len, delim)
    #
    |> xor(rate - 1, <<0x80>>)
    |> xorin(src, src_len - len, len)
    # Apply P
    |> keccakf()
  end

  defp squeeze(out, a, len, rate) do
    case out do
      <<_offset::binary-size(len), rest::binary()>> when len >= rate ->
        <<binary_part(a, 0, len)::binary(), rest::binary>>
        |> keccakf()
        |> squeeze(a, len - rate, rate)

      <<_offset::binary-size(len), rest::binary()>> ->
        <<binary_part(a, 0, len)::binary(), rest::binary()>>
    end
  end
end
