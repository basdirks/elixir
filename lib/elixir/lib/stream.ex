defmodule Stream do
  @moduledoc """
  Module for creating and composing streams.

  Streams are composable, lazy enumerables. Any enumerable that generates
  items one by one during enumeration is called a stream. For example,
  Elixir's `Range` is a stream:

      iex> range = 1..5
      1..5
      iex> Enum.map range, &(&1 * 2)
      [2,4,6,8,10]

  In the example above, as we mapped over the range, the elements being
  enumerated were created one by one, during enumeration. The `Stream`
  module allows us to map the range, without triggering its enumeration:

      iex> range = 1..3
      iex> stream = Stream.map(range, &(&1 * 2))
      iex> Enum.map(stream, &(&1 + 1))
      [3,5,7]

  Notice we started with a range and then we created a stream that is
  meant to multiply each item in the range by 2. At this point, no
  computation was done yet. Just when `Enum.map/2` is called we
  enumerate over each item in the range, multiplying it by 2 and adding 1.
  We say the functions in `Stream` are *lazy* and the functions in `Enum`
  are *eager*.

  Due to their laziness, streams are useful when working with large
  (or even infinite) collections. When chaining many operations with `Enum`,
  intermediate lists are created, while `Stream` creates a recipe of
  computations that are executed at a later moment. Let's see another
  example:

      1..3 |>
        Enum.map(&IO.inspect(&1)) |>
        Enum.map(&(&1 * 2)) |>
        Enum.map(&IO.inspect(&1))
      1
      2
      3
      2
      4
      6
      #=> [2,4,6]

  Notice that we first printed each item in the list, then multiplied each
  element by 2 and finally printed each new value. In this example, the list
  was enumerated three times. Let's see an example with streams:

      stream = 1..3 |>
        Stream.map(&IO.inspect(&1)) |>
        Stream.map(&(&1 * 2)) |>
        Stream.map(&IO.inspect(&1))
      Enum.to_list(stream)
      1
      2
      2
      4
      3
      6
      #=> [2,4,6]

  Although the end result is the same, the order in which the items were
  printed changed! With streams, we print the first item and then print
  its double. In this example, the list was enumerated just once!

  That's what we meant when we first said that streams are composable,
  lazy enumerables. Notice we could call `Stream.map/2` multiple times,
  effectively composing the streams and they are lazy. The computations
  are performed only when you call a function from the `Enum` module.

  ## Creating Streams

  There are many functions in Elixir's standard library that return
  streams, some examples are:

  * `IO.stream/1` - Streams input lines, one by one;
  * `URI.query_decoder/1` - Decodes a query string, pair by pair;

  This module also provides many convenience functions for creating streams,
  like `Stream.cycle/1`, `Stream.unfold/2`, `Stream.resource/3` and more.
  """

  defrecord Lazy, enum: nil, funs: [], accs: []

  defimpl Enumerable, for: Lazy do
    @compile :inline_list_funs

    def reduce(lazy, acc, fun) do
      do_reduce(lazy, acc, fn x, [acc] ->
        { reason, acc } = fun.(x, acc)
        { reason, [acc] }
      end)
    end

    def count(_lazy) do
      { :error, __MODULE__ }
    end

    def member?(_lazy, _value) do
      { :error, __MODULE__ }
    end

    defp do_reduce(Lazy[enum: enum, funs: funs, accs: accs], acc, fun) do
      composed = :lists.foldl(fn fun, acc -> fun.(acc) end, fun, funs)
      do_each(&Enumerable.reduce(enum, &1, composed), :lists.reverse(accs), acc)
    end

    defp do_each(_reduce, _accs, { :halt, acc }) do
      { :halted, acc }
    end

    defp do_each(reduce, accs, { :suspend, acc }) do
      { :suspended, acc, &do_each(reduce, accs, &1) }
    end

    defp do_each(reduce, accs, { :cont, acc }) do
      case reduce.({ :cont, [acc|accs] }) do
        { reason, [acc|_] } ->
          { reason, acc }
        { :suspended, [acc|accs], continuation } ->
          { :suspended, acc, &do_each(continuation, accs, &1) }
      end
    end
  end

  @type acc :: any
  @type element :: any
  @type index :: non_neg_integer
  @type default :: any

  # Require Stream.Reducers and its callbacks
  require Stream.Reducers, as: R

  defmacrop cont(f, entry, acc) do
    quote do: unquote(f).(unquote(entry), unquote(acc))
  end

  defmacrop acc(h, n, t) do
    quote do: [unquote(h),unquote(n)|unquote(t)]
  end

  defmacrop cont_with_acc(f, entry, h, n, t) do
    quote do
      { reason, [h|t] } = unquote(f).(unquote(entry), [unquote(h)|unquote(t)])
      { reason, [h,unquote(n)|t] }
    end
  end

  ## Transformers

  @doc """
  Lazily drops the next `n` items from the enumerable.

  ## Examples

      iex> stream = Stream.drop(1..10, 5)
      iex> Enum.to_list(stream)
      [6,7,8,9,10]

  """
  @spec drop(Enumerable.t, non_neg_integer) :: Enumerable.t
  def drop(enum, n) when n >= 0 do
    lazy enum, n, fn(f1) -> R.drop(f1) end
  end

  @doc """
  Lazily drops elements of the enumerable while the given
  function returns true.

  ## Examples

      iex> stream = Stream.drop_while(1..10, &(&1 <= 5))
      iex> Enum.to_list(stream)
      [6,7,8,9,10]

  """
  @spec drop_while(Enumerable.t, (element -> as_boolean(term))) :: Enumerable.t
  def drop_while(enum, fun) do
    lazy enum, true, fn(f1) -> R.drop_while(fun, f1) end
  end

  @doc """
  Execute the given function for each item.

  Useful for adding side effects (like printing) to a stream.

  ## Examples

      iex> stream = Stream.each([1, 2, 3], fn(x) -> IO.puts x end)
      iex> Enum.to_list(stream)
      1
      2
      3
      [1,2,3]

  """
  @spec each(Enumerable.t, (element -> term)) :: Enumerable.t
  def each(enum, fun) do
    lazy enum, fn(f1) ->
      fn(x, acc) ->
        fun.(x)
        f1.(x, acc)
      end
    end
  end

  @doc """
  Creates a stream that will filter elements according to
  the given function on enumeration.

  ## Examples

      iex> stream = Stream.filter([1, 2, 3], fn(x) -> rem(x, 2) == 0 end)
      iex> Enum.to_list(stream)
      [2]

  """
  @spec filter(Enumerable.t, (element -> as_boolean(term))) :: Enumerable.t
  def filter(enum, fun) do
    lazy enum, fn(f1) -> R.filter(fun, f1) end
  end

  @doc """
  Creates a stream that will apply the given function on
  enumeration.

  ## Examples

      iex> stream = Stream.map([1, 2, 3], fn(x) -> x * 2 end)
      iex> Enum.to_list(stream)
      [2,4,6]

  """
  @spec map(Enumerable.t, (element -> any)) :: Enumerable.t
  def map(enum, fun) do
    lazy enum, fn(f1) -> R.map(fun, f1) end
  end

  @doc """
  Creates a stream that will apply the given function on enumeration and
  flatten the result.

  ## Examples

      iex> stream = Stream.flat_map([1, 2, 3], fn(x) -> [x, x * 2] end)
      iex> Enum.to_list(stream)
      [1, 2, 2, 4, 3, 6]

  """
  @spec flat_map(Enumerable.t, (element -> any)) :: Enumerable.t
  def flat_map(enum, mapper) do
    &do_flat_map(enum, mapper, &1, &2)
  end

  defp do_flat_map(enumerables, mapper, acc, fun) do
    fun  = &do_flat_map_each(fun, &1, &2)
    step = &do_flat_map_step/2
    next = &Enumerable.reduce(enumerables, &1, step)
    do_flat_map([], next, mapper, acc, fun)
  end

  defp do_flat_map(next_acc, next, mapper, acc, fun) do
    case next.({ :cont, next_acc }) do
      { :suspended, [val|next_acc], next } ->
        enum = mapper.(val)
        do_flat_map(next_acc, next, mapper, acc, fun, &Enumerable.reduce(enum, &1, fun))
      { reason, _ } ->
        { reason, elem(acc, 1) }
    end
  end

  defp do_flat_map(next_acc, next, mapper, acc, fun, reduce) do
    try do
      reduce.(acc)
    catch
      { :stream_flat_map, h } -> { :halted, h }
    else
      { _, acc }              -> do_flat_map(next_acc, next, mapper, { :cont, acc }, fun)
      { :suspended, acc, c }  -> { :suspended, acc, &do_flat_map(next_acc, next, mapper, &1, fun, c) }
    end
  end

  defp do_flat_map_each(f, x, acc) do
    case f.(x, acc) do
      { :halt, h } -> throw({ :stream_flat_map, h })
      { _, _ } = o -> o
    end
  end

  defp do_flat_map_step(x, acc) do
    { :suspend, [x|acc] }
  end

  @doc """
  Creates a stream that will reject elements according to
  the given function on enumeration.

  ## Examples

      iex> stream = Stream.reject([1, 2, 3], fn(x) -> rem(x, 2) == 0 end)
      iex> Enum.to_list(stream)
      [1,3]

  """
  @spec reject(Enumerable.t, (element -> as_boolean(term))) :: Enumerable.t
  def reject(enum, fun) do
    lazy enum, fn(f1) -> R.reject(fun, f1) end
  end

  @doc """
  Lazily takes the next `n` items from the enumerable and stops
  enumeration.

  ## Examples

      iex> stream = Stream.take(1..100, 5)
      iex> Enum.to_list(stream)
      [1,2,3,4,5]

      iex> stream = Stream.cycle([1, 2, 3]) |> Stream.take(5)
      iex> Enum.to_list(stream)
      [1,2,3,1,2]

  """
  @spec take(Enumerable.t, non_neg_integer) :: Enumerable.t
  def take(enum, n) when n > 0 do
    lazy enum, n, fn(f1) -> R.take(f1) end
  end

  def take(_enum, 0), do: Lazy[enum: [], funs: [&(&1)]]

  @doc """
  Lazily takes elements of the enumerable while the given
  function returns true.

  ## Examples

      iex> stream = Stream.take_while(1..100, &(&1 <= 5))
      iex> Enum.to_list(stream)
      [1,2,3,4,5]

  """
  @spec take_while(Enumerable.t, (element -> as_boolean(term))) :: Enumerable.t
  def take_while(enum, fun) do
    lazy enum, fn(f1) -> R.take_while(fun, f1) end
  end

  @doc """
  Creates a stream where each item in the enumerable will
  be accompanied by its index.

  ## Examples

      iex> stream = Stream.with_index([1, 2, 3])
      iex> Enum.to_list(stream)
      [{1,0},{2,1},{3,2}]

  """
  @spec with_index(Enumerable.t) :: Enumerable.t
  def with_index(enum) do
    lazy enum, 0, fn(f1) -> R.with_index(f1) end
  end

  ## Combiners

  @doc """
  Creates a stream that enumerates each enumerable in an enumerable.

  ## Examples

      iex> stream = Stream.concat([1..3, 4..6, 7..9])
      iex> Enum.to_list(stream)
      [1,2,3,4,5,6,7,8,9]

  """
  @spec concat(Enumerable.t) :: Enumerable.t
  def concat(enumerables) do
    flat_map(enumerables, &(&1))
  end

  @doc """
  Creates a stream that enumerates the first argument, followed by the second.

  ## Examples

      iex> stream = Stream.concat(1..3, 4..6)
      iex> Enum.to_list(stream)
      [1,2,3,4,5,6]

      iex> stream1 = Stream.cycle([1, 2, 3])
      iex> stream2 = Stream.cycle([4, 5, 6])
      iex> stream = Stream.concat(stream1, stream2)
      iex> Enum.take(stream, 6)
      [1,2,3,1,2,3]

  """
  @spec concat(Enumerable.t, Enumerable.t) :: Enumerable.t
  def concat(first, second) do
    flat_map([first, second], &(&1))
  end

  @doc """
  Zips two collections together, lazily.

  The zipping finishes as soon as any enumerable completes.

  ## Examples

      iex> concat = Stream.concat(1..3, 4..6)
      iex> cycle  = Stream.cycle([:a, :b, :c])
      iex> Stream.zip(concat, cycle) |> Enum.to_list
      [{1,:a},{2,:b},{3,:c},{4,:a},{5,:b},{6,:c}]

  """
  @spec zip(Enumerable.t, Enumerable.t) :: Enumerable.t
  def zip(left, right) do
    step      = &do_zip_step(&1, &2)
    left_fun  = &Enumerable.reduce(left, &1, step)
    right_fun = &Enumerable.reduce(right, &1, step)

    # Return a function as a lazy enumerator.
    &do_zip(left_fun, [], right_fun, [], &1, &2)
  end

  defp do_zip(_left_fun, _left_acc, _right_fun, _right_acc, { :halt, acc }, _fun) do
    { :halted, acc }
  end

  defp do_zip(left_fun, left_acc, right_fun, right_acc, { :suspend, acc }, fun) do
    { :suspended, acc, &do_zip(left_fun, left_acc, right_fun, right_acc, &1, fun) }
  end

  defp do_zip(left_fun, left_acc, right_fun, right_acc, { :cont, acc }, callback) do
    case left_fun.({ :cont, left_acc }) do
      { :suspended, [x|left_acc], left_fun } ->
        case right_fun.({ :cont, right_acc }) do
          { :suspended, [y|right_acc], right_fun } ->
            do_zip(left_fun, left_acc, right_fun, right_acc, callback.({ x, y }, acc), callback)
          { reason, _ } ->
            { reason, acc }
        end
      { reason, _ } ->
        { reason, acc }
    end
  end

  defp do_zip_step(x, acc) do
    { :suspend, [x|acc] }
  end

  ## Sources

  @doc """
  Creates a stream that cycles through the given enumerable,
  infinitely.

  ## Examples

      iex> stream = Stream.cycle([1,2,3])
      iex> Enum.take(stream, 5)
      [1,2,3,1,2]

  """
  @spec cycle(Enumerable.t) :: Enumerable.t
  def cycle(enumerable) do
    fn acc, fun ->
      reduce = &Enumerable.reduce(enumerable, &1, fun)
      do_cycle(reduce, reduce, acc)
    end
  end

  defp do_cycle(_reduce, _cycle, { :halt, acc }) do
    { :halted, acc }
  end

  defp do_cycle(reduce, cycle, { :suspend, acc }) do
    { :suspended, acc, &do_cycle(reduce, cycle, &1) }
  end

  defp do_cycle(reduce, cycle, acc) do
    case reduce.(acc) do
      { :done, acc } ->
        do_cycle(cycle, cycle, { :cont, acc })
      { :halted, acc } ->
        { :halted, acc }
      { :suspended, acc, continuation } ->
        { :suspended, acc, &do_cycle(continuation, cycle, &1) }
    end
  end

  @doc """
  Emit a sequence of values, starting with `start_value`. Successive
  values are generated by calling `next_fun` on the previous value.

  ## Examples

      iex> Stream.iterate(0, &(&1+1)) |> Enum.take(5)
      [0,1,2,3,4]

  """
  @spec iterate(element, (element -> element)) :: Enumerable.t
  def iterate(start_value, next_fun) do
    unfold({ :ok, start_value}, fn
      { :ok, value } ->
        { value, { :next, value } }
      { :next, value } ->
        next = next_fun.(value)
        { next, { :next, next } }
    end)
  end

  @doc """
  Returns a stream generated by calling `generator_fun` repeatedly.

  ## Examples

      iex> Stream.repeatedly(&:random.uniform/0) |> Enum.take(3)
      [0.4435846174457203, 0.7230402056221108, 0.94581636451987]

  """
  @spec repeatedly((() -> element)) :: Enumerable.t
  def repeatedly(generator_fun) when is_function(generator_fun, 0) do
    &do_repeatedly(generator_fun, &1, &2)
  end

  defp do_repeatedly(generator_fun, { :suspend, acc }, fun) do
    { :suspended, acc, &do_repeatedly(generator_fun, &1, fun) }
  end

  defp do_repeatedly(_generator_fun, { :halt, acc }, _fun) do
    { :halted, acc }
  end

  defp do_repeatedly(generator_fun, { :cont, acc }, fun) do
    do_repeatedly(generator_fun, fun.(generator_fun.(), acc), fun)
  end

  @doc """
  Emits a sequence of values for the given resource.

  Similar to `unfold/2` but the initial value is computed lazily via
  `start_fun` and executes an `after_fun` at the end of enumeration
  (both in cases of success and failure).

  Successive values are generated by calling `next_fun` with the
  previous accumulator (the initial value being the result returned
  by `start_fun`) and it must return a tuple with the current and
  next accumulator. The enumeration finishes if it returns nil.

  As the name says, this function is useful to stream values from
  resources.

  ## Examples

      Stream.resource(fn -> File.open("sample") end,
                      fn file ->
                        case IO.readline(file) do
                          data when is_binary(file) -> { data, file }
                          _ -> nil
                        end
                      end,
                      fn file -> File.close!(file) end)

  """
  @spec resource((() -> acc), (acc -> { element, acc } | nil), (acc -> term)) :: Enumerable.t
  def resource(start_fun, next_fun, after_fun) do
    fn acc, fun ->
      next_acc = start_fun.()
      try do
        do_unfold(next_acc, next_fun, acc, fun)
      after
        after_fun.(next_acc)
      end
    end
  end

  @doc """
  Emits a sequence of values for the given accumulator.

  Successive values are generated by calling `next_fun` with the previous
  accumulator and it must return a tuple with the current and next
  accumulator. The enumeration finishes if it returns nil.

  ## Examples

      iex> Stream.unfold(5, fn 0 -> nil; n -> {n, n-1} end) |> Enum.to_list()
      [5, 4, 3, 2, 1]
  """
  @spec unfold(acc, (acc -> { element, acc } | nil)) :: Enumerable.t
  def unfold(next_acc, next_fun) do
    &do_unfold(next_acc, next_fun, &1, &2)
  end

  defp do_unfold(next_acc, next_fun, { :suspend, acc }, fun) do
    { :suspended, acc, &do_unfold(next_acc, next_fun, &1, fun) }
  end

  defp do_unfold(_next_acc, _next_fun, { :halt, acc }, _fun) do
    { :halted, acc }
  end

  defp do_unfold(next_acc, next_fun, { :cont, acc }, fun) do
    case next_fun.(next_acc) do
      nil             -> { :done, acc }
      { v, next_acc } -> do_unfold(next_acc, next_fun, fun.(v, acc), fun)
    end
  end

  ## Helpers

  @compile { :inline, lazy: 2, lazy: 3 }

  defp lazy(enum, fun) do
    case enum do
      Lazy[funs: funs] = lazy ->
        lazy.funs([fun|funs])
      _ ->
        Lazy[enum: enum, funs: [fun], accs: []]
    end
  end

  defp lazy(enum, acc, fun) do
    case enum do
      Lazy[funs: funs, accs: accs] = lazy ->
        lazy.funs([fun|funs]).accs([acc|accs])
      _ ->
        Lazy[enum: enum, funs: [fun], accs: [acc]]
    end
  end
end
