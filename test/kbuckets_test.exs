# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule KBucketsTest do
  use Bitwise
  use ExUnit.Case

  alias KBuckets.Item

  setup do
    # Setting
    # before = Diode.miner()
    Model.CredSql.set_wallet(node_id("abcd"))
  end

  test "initialize" do
    kb = KBuckets.new()
    assert KBuckets.size(kb) == 1
    assert KBuckets.bucket_count(kb) == 1
  end

  test "k inserts" do
    kb = KBuckets.new()

    kb =
      Enum.reduce(nodes(20), kb, fn node, acc ->
        KBuckets.insert_item(acc, node)
      end)

    assert KBuckets.size(kb) == 21
    assert KBuckets.bucket_count(kb) == 2
  end

  test "self duplicate bug" do
    kb =
      KBuckets.new()
      |> KBuckets.insert_item(%Item{node_id: node_id("abcd"), last_connected: 1})

    assert KBuckets.size(kb) == 1
  end

  test "conflict" do
    conflicts = conflicts()
    kb = KBuckets.new()

    kb =
      Enum.reduce(nodes(100), kb, fn node, acc ->
        acc2 = KBuckets.insert_item(acc, node)

        # if acc == acc2 do
        #   :io.format("~s,~n", [Base16.encode(KBuckets.key(node))])
        # end

        if MapSet.member?(conflicts, :binary.decode_unsigned(KBuckets.key(node))) do
          assert acc2 == acc
        else
          assert acc2 != acc
        end

        acc2
      end)

    assert KBuckets.size(kb) == 101 - MapSet.size(conflicts)
  end

  test "nearest" do
    kb = KBuckets.new()

    kb =
      Enum.reduce(nodes(100), kb, fn node, acc ->
        KBuckets.insert_item(acc, node)
      end)

    assert KBuckets.size(kb) == 63

    # Should only return self as nearest result
    near = KBuckets.nearer_n(kb, KBuckets.self(kb), KBuckets.k())
    assert Enum.member?(near, KBuckets.self(kb))
    assert length(near) == 1

    # Should be exactly @k
    opposite = binary_not(KBuckets.key(node_id("abcd")))
    near = KBuckets.nearest_n(kb, opposite, KBuckets.k())
    assert not Enum.member?(near, KBuckets.self(kb))
    assert length(near) == 20

    # Checking that distance is correct
    ref =
      KBuckets.to_list(kb)
      |> Enum.sort(fn a, b -> KBuckets.distance(opposite, a) < KBuckets.distance(opposite, b) end)
      |> Enum.take(20)
      |> Enum.sort()

    assert ref == Enum.sort(near)

    nearer = KBuckets.nearest_n(kb, opposite, div(KBuckets.k(), 2))
    assert not Enum.member?(nearer, KBuckets.self(kb))
    assert length(nearer) == div(KBuckets.k(), 2)

    nearest = KBuckets.nearest_n(kb, opposite, 1)
    assert not Enum.member?(nearest, KBuckets.self(kb))
    assert length(nearest) == 1
  end

  test "symmetric distance" do
    for x <- 1..100 do
      a = node_id("distance_a_#{x}")
      b = node_id("distance_b_#{x}")
      assert KBuckets.distance(a, b) == KBuckets.distance(b, a)
    end
  end

  test "no duplicate" do
    kb =
      KBuckets.new()
      |> KBuckets.insert_item(%Item{node_id: node_id([1]), last_connected: 1})
      |> KBuckets.insert_item(%Item{node_id: node_id([1]), last_connected: 2})

    assert KBuckets.size(kb) == 2
  end

  test "unique()" do
    items = [
      %Item{node_id: node_id([1]), last_connected: 1},
      %Item{node_id: node_id([1]), last_connected: 2}
    ]

    unique = KBuckets.unique(items)

    assert length(unique) == 1
    assert List.last(items) == List.first(unique)
  end

  test "deletes" do
    kb = KBuckets.new()

    kb =
      Enum.reduce(nodes(20), kb, fn node, acc ->
        KBuckets.insert_item(acc, node)
      end)

    assert KBuckets.size(kb) == 21
    assert KBuckets.bucket_count(kb) == 2

    kb =
      Enum.reduce(nodes(10), kb, fn node, acc ->
        KBuckets.delete_item(acc, node)
      end)

    assert KBuckets.size(kb) == 11
    assert KBuckets.bucket_count(kb) == 2
  end

  ##
  ## Helper functions
  ##
  defp binary_not(bin) do
    :erlang.binary_to_list(bin)
    |> Enum.map(fn x -> rem(x + 128, 256) end)
    |> :erlang.list_to_binary()
  end

  def nodes(num) do
    Enum.map(1..num, fn idx ->
      %Item{node_id: node_id([idx]), last_connected: idx}
    end)
  end

  def node_id(x) do
    Wallet.from_privkey(Diode.hash(x))
  end

  defp conflicts() do
    MapSet.new([
      0x76845D8B998ED998EDE6D72699D6017FF24D272A7C4E9304E7132348B3B64901,
      0x5570D3BB0BFEFE72923F3CBB97A3FFD92D9EA8C1B897D42D100237F2F330C3C9,
      0x36A21F3959C781A900C00EA850107A5B8950E6E6BB9E7676C18A88BE683FDD09,
      0x21851F4A5F32AA4D4DD2F81A3418FE3522FBA28FE28B03019F5B9A169CEDA982,
      0x4E97F68C397CFB0086A799C9F924A9C44E008F6F0E177268C865F36F2C8EC796,
      0x4FFFA6A5A57B7AF5DA7B000F23F76CF9B03F4CC0EB2575A6BF69F1038C762BF8,
      0x4E105342DDA596938A3442992B95F65E8A170E7F7AC1B4F4EAA6A883D2CBB720,
      0x7CFC236DA2FE1012AA8CBA5F6ACF07F5C5AB2CC0E3730C16CC21948EE163F198,
      0x532FCFE60B9ADD4BECEADA031D3AA65766C98A4712CAEDECCE8CF5E2B265A68F,
      0x346CD1CCA349ACD647908A14003515EADCB74F7380BEFFF95CDDE4D5810238B8,
      0x6619432F3111E7C5888E62D2CC0C242CBD7925A552D45B0F8C759E10A469B5D0,
      0x7193E0436AE15A35D10543A1155C0DD4737A476C06759E3D7C39027D64BB6686,
      0x2FAC166CC373F50CD33D8FA8B9B5FBE6B65FFFFEF26FAB30719D9665A88DF488,
      0x3A1E2B228B7198FA5CA6974B02A9F88BF6025230FC6B4C22031211B2920EE0BB,
      0x7C4BA7A4BD52D015097B2EAF95369EECB7BFD6E3A25831AEA385D8E2C0238D6D,
      0x22AEA7128E1A6F51441141CA4A3CB0E800B7C94121B9C8E25A811DDC9944712F,
      0x3EDD2C02E082D717BB4DBC0973C943DCADC7A89EB47E1310101EE300F0012201,
      0x6EB64E616C6B19D6A1ED6DAA71D88953C359B5CDA56ADF8BD6498C878C95F2CF,
      0x7450AB488F193071174DAA8D26FFF5D1803F1CE492DC04C8440EEBA2B759BE7F,
      0x6CB3F35798E917C3759F661403B25904F7D41F708C63B65881E3B8313845E258,
      0x1597F36BCE9BFC2D6E3748C783329A83B1A339034A08A995FA49864545F4C49E,
      0x1686DDA3AE796B3559D67C094D85B7ABFB33DFB754921EF9B65636C1752C7B7D,
      0x5C9EF6D66642B69D50BFE1F5252730CC96100FA68081667CF4D0FFB25E267E92,
      0x08CBAF17B6D6F9497616E6F126760608AA02022FC20423F83D3DC343437038A3,
      0x0DA7CF58E627ECE766D6F64F04A79A159919186CD9894D96B03FB0BD9D646C37,
      0x11B1683A1D57A7A3BA8CF6E4540510055EEB92F830757F7DD76C235BAEF31ACF,
      0x1ED678C64A6CEE3E456B79BD8CC668476D6E45582B62E0119E1513693752A6D7,
      0x6550571B3F5A1E6868A6932B892E3C83678B1A85AE0D3A29982D8E4BEF91C362,
      0x29BEC2A5B2F1B8F55507B56A8E7979CBDF36CB5FB5AA41D2CC2F1772A737C5C0,
      0x4A2310B045E2B209516969C85602A494C1CCC1521A99DD5BBF71D321463326F2,
      0x362B5FD0F9FC136C1A5B1BC3495F207C00369DA6F3AFA2879E8829BC3DFC4D79,
      0x144B3C1585E793E47C772D414B4F356462118ECAA29B1FFFD25772F6F1D36EAC,
      0x12F832E50523F2518170D2B80B0B7C4C5FA73662107EF4CBE51E5D049873B9BC,
      0xF79FB9A018DC062DC4B7EBBBC9A518C3BFF968B33DC1ADEFA023D514EAEEA360,
      0x71FB506B2FB906F243C093CE0111C7887C75CAAFDCF2FA748D84EABF3FCE74DD,
      0x25BE5EA5E7AEA826D74554861364923890412D360D8D43562284B1355054C07C,
      0x1B3D9084B18848806F6F8F0C3308FFB304F86262CC0A22E5EC9CA811B7DC4D42,
      0x291D3E4A1F6201C7D9B27F19901C36D6CA1049F9ECCBA2B9824B86E45D47B54D
    ])
  end
end
