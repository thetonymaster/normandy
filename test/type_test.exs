defmodule Normandy.TypeTest do
  use ExUnit.Case, async: true

  defmodule Custom do
    use Normandy.Type
    def type, do: :custom
    def dump(_), do: {:ok, :dump}
    def cast(_), do: {:ok, :cast}
    def equal?(true, _), do: true
    def equal?(_, _), do: false
    def embed_as(_), do: :dump
  end

  defmodule CustomAny do
    use Normandy.Type
    def type, do: :any
    def dump(_), do: {:ok, :dump}
    def cast(_), do: {:ok, :cast}
  end

  defmodule CustomWithCastError do
    use Normandy.Type

    def type, do: :any
    def dump(_), do: {:ok, :dump}
    def cast("a"), do: {:ok, "a"}
    def cast("b"), do: {:error, foo: :bar, value: "b"}
    def cast("c"), do: {:error, foo: :bar, source: [:email], value: "c"}
    def cast("d"), do: {:error, message: "custom message"}
  end

  defmodule CustomParameterizedTypeWithFormat do
    use Normandy.ParameterizedType

    def init(_options), do: :init
    def type(_), do: :custom
    def dump(_, _, _), do: {:ok, :dump}
    def cast(_, _), do: {:ok, :cast}
    def equal?(true, _, _), do: true
    def equal?(_, _, _), do: false
    def format(_params), do: "#CustomParameterizedTypeWithFormat<:custom>"
  end

  defmodule CustomParameterizedTypeWithoutFormat do
    use Normandy.ParameterizedType

    def init(_options), do: :init
    def type(_), do: :custom
    def dump(_, _, _), do: {:ok, :dump}
    def cast(_, _), do: {:ok, :cast}
    def equal?(true, _, _), do: true
    def equal?(_, _, _), do: false
  end

  defmodule Schema do
    use Normandy.Schema

    schema do
      field(:c, :integer, default: 0)
    end
  end

  import Kernel, except: [match?: 2], warn: false
  import Normandy.Type
  doctest Normandy.Type

  test "embed_as" do
    assert embed_as(:string, :json) == :self
    assert embed_as(:integer, :json) == :self
    assert embed_as(Custom, :json) == :dump
    assert embed_as(CustomAny, :json) == :self
  end

  test "embedded_dump" do
    assert embedded_dump(Custom, :value, :json) == {:ok, :dump}
  end

  test "custom types" do
    assert dump(Custom, "foo") == {:ok, :dump}
    assert cast(Custom, "foo") == {:ok, :cast}
    assert cast(CustomWithCastError, "a") == {:ok, "a"}
    assert cast(CustomWithCastError, "b") == {:error, foo: :bar, value: "b"}
    assert cast(CustomWithCastError, "c") == {:error, foo: :bar, source: [:email], value: "c"}

    assert_raise Normandy.CastError,
                 "cannot cast \"b\" to Normandy.TypeTest.CustomWithCastError",
                 fn ->
                   cast!(CustomWithCastError, "b")
                 end

    assert_raise Normandy.CastError, "custom message", fn ->
      cast!(CustomWithCastError, "d")
    end

    assert dump(Custom, nil) == {:ok, nil}
    assert cast(Custom, nil) == {:ok, nil}
    assert cast(CustomWithCastError, nil) == {:ok, nil}

    assert match?(Custom, :any)
    assert match?(:any, Custom)
    assert match?(CustomAny, :boolean)
  end

  test "untyped maps" do
    assert dump(:map, %{a: 1}) == {:ok, %{a: 1}}
    assert dump(:map, 1) == :error
  end

  test "typed maps" do
    assert dump({:map, :integer}, %{"a" => 1, "b" => 2}) == {:ok, %{"a" => 1, "b" => 2}}
    assert cast({:map, :integer}, %{"a" => "1", "b" => "2"}) == {:ok, %{"a" => 1, "b" => 2}}

    assert dump({:map, :integer}, %{"a" => 1, "b" => nil}) == {:ok, %{"a" => 1, "b" => nil}}
    assert cast({:map, :integer}, %{"a" => "1", "b" => nil}) == {:ok, %{"a" => 1, "b" => nil}}

    assert dump({:map, {:array, :integer}}, %{"a" => [0, 0], "b" => [1, 1]}) ==
             {:ok, %{"a" => [0, 0], "b" => [1, 1]}}

    assert cast({:map, {:array, :integer}}, %{"a" => [0, 0], "b" => [1, 1]}) ==
             {:ok, %{"a" => [0, 0], "b" => [1, 1]}}

    assert dump({:map, :integer}, %{"a" => ""}) == :error
    assert cast({:map, :integer}, %{"a" => ""}) == :error

    assert dump({:map, :integer}, 1) == :error
    assert cast({:map, :integer}, 1) == :error
  end

  test "array" do
    assert dump({:array, :integer}, [2]) == {:ok, [2]}
    assert dump({:array, :integer}, [2, nil]) == {:ok, [2, nil]}
    assert cast({:array, :integer}, [3]) == {:ok, [3]}
    assert cast({:array, :integer}, ["3"]) == {:ok, [3]}
    assert cast({:array, :integer}, [3, nil]) == {:ok, [3, nil]}
    assert cast({:array, :integer}, ["3", nil]) == {:ok, [3, nil]}
  end

  test "custom types with array" do
    assert dump({:array, Custom}, ["foo"]) == {:ok, [:dump]}
    assert cast({:array, Custom}, ["foo"]) == {:ok, [:cast]}

    assert cast({:array, CustomWithCastError}, ["b"]) ==
             {:error, foo: :bar, value: "b", source: [0]}

    assert cast({:array, CustomWithCastError}, ["a", "a", "a", "b"]) ==
             {:error, foo: :bar, value: "b", source: [3]}

    assert cast({:array, CustomWithCastError}, ["c"]) ==
             {:error, foo: :bar, source: [0, :email], value: "c"}

    assert cast({:array, CustomWithCastError}, ["a", "a", "c", "a"]) ==
             {:error, foo: :bar, source: [2, :email], value: "c"}

    assert dump({:array, Custom}, [nil]) == {:ok, [nil]}
    assert cast({:array, Custom}, [nil]) == {:ok, [nil]}
    assert cast({:array, CustomWithCastError}, [nil]) == {:ok, [nil]}

    assert dump({:array, Custom}, nil) == {:ok, nil}
    assert cast({:array, Custom}, nil) == {:ok, nil}
    assert cast({:array, CustomWithCastError}, nil) == {:ok, nil}

    assert dump({:array, Custom}, 1) == :error
    assert cast({:array, Custom}, 1) == :error
    assert cast({:array, CustomWithCastError}, 1) == :error

    assert dump({:array, Custom}, [:unused], fn Custom, _ -> {:ok, :used} end) == {:ok, [:used]}
  end

  test "custom types with map" do
    assert dump({:map, Custom}, %{"x" => "foo"}) == {:ok, %{"x" => :dump}}
    assert cast({:map, Custom}, %{"x" => "foo"}) == {:ok, %{"x" => :cast}}

    assert cast({:map, CustomWithCastError}, %{"x" => "b"}) ==
             {:error, foo: :bar, value: "b", source: ["x"]}

    assert cast({:map, CustomWithCastError}, %{"x" => "a", "y" => "a", "z" => "a", "u" => "b"}) ==
             {:error, foo: :bar, value: "b", source: ["u"]}

    assert cast({:map, CustomWithCastError}, %{"x" => "c"}) ==
             {:error, foo: :bar, source: ["x", :email], value: "c"}

    assert cast({:map, CustomWithCastError}, %{"x" => "a", "y" => "a", "z" => "c", "u" => "a"}) ==
             {:error, foo: :bar, source: ["z", :email], value: "c"}

    assert dump({:map, Custom}, %{"x" => nil}) == {:ok, %{"x" => nil}}
    assert cast({:map, Custom}, %{"x" => nil}) == {:ok, %{"x" => nil}}
    assert cast({:map, CustomWithCastError}, %{"x" => nil}) == {:ok, %{"x" => nil}}

    assert dump({:map, Custom}, nil) == {:ok, nil}
    assert cast({:map, Custom}, nil) == {:ok, nil}
    assert cast({:map, CustomWithCastError}, nil) == {:ok, nil}

    assert dump({:map, Custom}, 1) == :error
    assert cast({:map, Custom}, 1) == :error
    assert cast({:map, CustomWithCastError}, 1) == :error

    assert dump({:map, Custom}, %{"a" => :unused}, fn Custom, _ -> {:ok, :used} end) ==
             {:ok, %{"a" => :used}}
  end

  test "dump with custom function" do
    dumper = fn :integer, term -> {:ok, term * 2} end
    assert dump({:array, :integer}, [1, 2], dumper) == {:ok, [2, 4]}
    assert dump({:map, :integer}, %{x: 1, y: 2}, dumper) == {:ok, %{x: 2, y: 4}}
  end

  test "in" do
    assert cast({:in, :integer}, ["1", "2", "3"]) == {:ok, [1, 2, 3]}
    assert {:ok, list} = cast({:in, :integer}, MapSet.new(~w(1 2 3)))
    assert [1, 2, 3] = Enum.sort(list)
    assert cast({:in, :integer}, nil) == :error
  end

  test "integer" do
    assert cast(:integer, String.duplicate("1", 64)) == :error
  end

  @date ~D[2015-12-31]
  @leap_date ~D[2000-02-29]
  @date_unix_epoch ~D[1970-01-01]

  describe "date" do
    test "cast" do
      assert Normandy.Type.cast(:date, @date) == {:ok, @date}

      assert Normandy.Type.cast(:date, "2015-12-31") == {:ok, @date}
      assert Normandy.Type.cast(:date, "2000-02-29") == {:ok, @leap_date}
      assert Normandy.Type.cast(:date, "2015-00-23") == :error
      assert Normandy.Type.cast(:date, "2015-13-23") == :error
      assert Normandy.Type.cast(:date, "2015-01-00") == :error
      assert Normandy.Type.cast(:date, "2015-01-32") == :error
      assert Normandy.Type.cast(:date, "2015-02-29") == :error
      assert Normandy.Type.cast(:date, "1900-02-29") == :error

      assert Normandy.Type.cast(:date, %{"year" => "2015", "month" => "12", "day" => "31"}) ==
               {:ok, @date}

      assert Normandy.Type.cast(:date, %{year: 2015, month: 12, day: 31}) ==
               {:ok, @date}

      assert Normandy.Type.cast(:date, %{"year" => "", "month" => "", "day" => ""}) ==
               {:ok, nil}

      assert Normandy.Type.cast(:date, %{year: nil, month: nil, day: nil}) ==
               {:ok, nil}

      assert Normandy.Type.cast(:date, %{"year" => "2015", "month" => "", "day" => "31"}) ==
               :error

      assert Normandy.Type.cast(:date, %{"year" => "2015", "month" => nil, "day" => "31"}) ==
               :error

      assert Normandy.Type.cast(:date, %{"year" => "2015", "month" => nil}) ==
               :error

      assert Normandy.Type.cast(:date, %{"year" => "", "month" => "01", "day" => "30"}) ==
               :error

      assert Normandy.Type.cast(:date, %{"year" => nil, "month" => "01", "day" => "30"}) ==
               :error

      assert Normandy.Type.cast(:date, DateTime.from_unix!(10)) ==
               {:ok, @date_unix_epoch}

      assert Normandy.Type.cast(:date, ~N[1970-01-01 12:23:34]) ==
               {:ok, @date_unix_epoch}

      assert Normandy.Type.cast(:date, @date) ==
               {:ok, @date}

      assert Normandy.Type.cast(:date, ~T[12:23:34]) ==
               :error

      assert Normandy.Type.cast(:date, "2015-12-31T00:00:00") == {:ok, @date}
      assert Normandy.Type.cast(:date, "2015-12-31 00:00:00") == {:ok, @date}
    end

    test "dump" do
      assert Normandy.Type.dump(:date, @date) == {:ok, @date}
      assert Normandy.Type.dump(:date, @leap_date) == {:ok, @leap_date}
      assert Normandy.Type.dump(:date, @date_unix_epoch) == {:ok, @date_unix_epoch}
    end
  end

  @time ~T[23:50:07]
  @time_zero ~T[23:50:00]
  @time_usec ~T[23:50:07.030000]

  describe "time" do
    test "cast" do
      assert Normandy.Type.cast(:time, @time) == {:ok, @time}
      assert Normandy.Type.cast(:time, @time_usec) == {:ok, @time}
      assert Normandy.Type.cast(:time, @time_zero) == {:ok, @time_zero}

      assert Normandy.Type.cast(:time, "23:50") == {:ok, @time_zero}
      assert Normandy.Type.cast(:time, "23:50:07") == {:ok, @time}
      assert Normandy.Type.cast(:time, "23:50:07Z") == {:ok, @time}
      assert Normandy.Type.cast(:time, "23:50:07.030000") == {:ok, @time}
      assert Normandy.Type.cast(:time, "23:50:07.030000Z") == {:ok, @time}

      assert Normandy.Type.cast(:time, "24:01") == :error
      assert Normandy.Type.cast(:time, "00:61") == :error
      assert Normandy.Type.cast(:time, "00:00.123") == :error
      assert Normandy.Type.cast(:time, "00:00Z") == :error
      assert Normandy.Type.cast(:time, "24:01:01") == :error
      assert Normandy.Type.cast(:time, "00:61:00") == :error
      assert Normandy.Type.cast(:time, "00:00:61") == :error
      assert Normandy.Type.cast(:time, "00:00:009") == :error
      assert Normandy.Type.cast(:time, "00:00:00.A00") == :error

      assert Normandy.Type.cast(:time, %{"hour" => "23", "minute" => "50", "second" => "07"}) ==
               {:ok, @time}

      assert Normandy.Type.cast(:time, %{hour: 23, minute: 50, second: 07}) ==
               {:ok, @time}

      assert Normandy.Type.cast(:time, %{"hour" => "", "minute" => ""}) ==
               {:ok, nil}

      assert Normandy.Type.cast(:time, %{hour: nil, minute: nil}) ==
               {:ok, nil}

      assert Normandy.Type.cast(:time, %{"hour" => "23", "minute" => "50"}) ==
               {:ok, @time_zero}

      assert Normandy.Type.cast(:time, %{hour: 23, minute: 50}) ==
               {:ok, @time_zero}

      assert Normandy.Type.cast(:time, %{
               hour: 23,
               minute: 50,
               second: 07,
               microsecond: 30_000
             }) ==
               {:ok, @time}

      assert Normandy.Type.cast(:time, %{
               "hour" => 23,
               "minute" => 50,
               "second" => 07,
               "microsecond" => 30_000
             }) ==
               {:ok, @time}

      assert Normandy.Type.cast(:time, %{"hour" => "", "minute" => "50"}) ==
               :error

      assert Normandy.Type.cast(:time, %{hour: 23, minute: nil}) ==
               :error

      assert Normandy.Type.cast(:time, ~N[2016-11-11 23:30:10]) ==
               {:ok, ~T[23:30:10]}

      assert Normandy.Type.cast(:time, ~D[2016-11-11]) ==
               :error
    end

    test "dump" do
      assert Normandy.Type.dump(:time, @time) == {:ok, @time}
      assert Normandy.Type.dump(:time, @time_zero) == {:ok, @time_zero}

      assert_raise ArgumentError, ~r":time expects microseconds to be empty", fn ->
        Normandy.Type.dump(:time, @time_usec)
      end
    end
  end

  describe "equal?/3" do
    test "primitive" do
      assert Normandy.Type.equal?(:integer, 1, 1)
      refute Normandy.Type.equal?(:integer, 1, 2)
      refute Normandy.Type.equal?(:integer, 1, "1")
      refute Normandy.Type.equal?(:integer, 1, nil)
    end

    test "composite primitive" do
      assert Normandy.Type.equal?({:array, :integer}, [1], [1])
      refute Normandy.Type.equal?({:array, :integer}, [1], [2])
      refute Normandy.Type.equal?({:array, :integer}, [1, 1], [1])
      refute Normandy.Type.equal?({:array, :integer}, [1], [1, 1])
    end

    test "semantical comparison" do
      assert Normandy.Type.equal?(:time, ~T[09:00:00], ~T[09:00:00.000000])
      refute Normandy.Type.equal?(:time, ~T[09:00:00], ~T[09:00:00.999999])
    end

    test "custom semantical comparison" do
      assert Normandy.Type.equal?(Custom, true, false)
      refute Normandy.Type.equal?(Custom, false, false)
    end

    test "nil values" do
      assert Normandy.Type.equal?(:any, nil, nil)
      assert Normandy.Type.equal?(:boolean, nil, nil)
      assert Normandy.Type.equal?(:binary, nil, nil)
      assert Normandy.Type.equal?(:date, nil, nil)
      assert Normandy.Type.equal?(:float, nil, nil)
      assert Normandy.Type.equal?(:id, nil, nil)
      assert Normandy.Type.equal?(:integer, nil, nil)
      assert Normandy.Type.equal?(:map, nil, nil)
      assert Normandy.Type.equal?(:string, nil, nil)
      assert Normandy.Type.equal?(:time, nil, nil)

      term = [~T[10:10:10], nil]
      assert Normandy.Type.equal?({:array, :time}, term, term)

      term = %{one: nil, two: ~T[10:10:10]}
      assert Normandy.Type.equal?({:map, :time}, term, term)

      assert Normandy.Type.equal?(Custom, nil, nil)
    end
  end

  describe "format/1" do
    test "parameterized type with format/1 defined" do
      params = %{}

      assert Normandy.Type.format({:parameterized, {CustomParameterizedTypeWithFormat, params}}) ==
               "#CustomParameterizedTypeWithFormat<:custom>"
    end

    test "parameterized type without format/1 defined" do
      type = {:parameterized, {CustomParameterizedTypeWithoutFormat, %{key: :value}}}

      assert Normandy.Type.format(type) ==
               "#Normandy.TypeTest.CustomParameterizedTypeWithoutFormat<%{key: :value}>"
    end

    test "composite parameterized type" do
      params = %{}
      with_format_defined = {:parameterized, {CustomParameterizedTypeWithFormat, params}}
      without_format_defined = {:parameterized, {CustomParameterizedTypeWithoutFormat, params}}

      assert Normandy.Type.format({:array, with_format_defined}) ==
               "{:array, #CustomParameterizedTypeWithFormat<:custom>}"

      assert Normandy.Type.format({:array, without_format_defined}) ==
               "{:array, #Normandy.TypeTest.CustomParameterizedTypeWithoutFormat<%{}>}"
    end

    test "non parameterized type" do
      # fallback to `inspect(type)`
      assert Normandy.Type.format(:id) == ":id"
    end

    test "composite non parameterized type" do
      # fallback to `inspect(type)`
      assert Normandy.Type.format({:array, :id}) == "{:array, :id}"

      assert Normandy.Type.format({:array, {:map, :integer}}) ==
               "{:array, {:map, :integer}}"
    end
  end
end
