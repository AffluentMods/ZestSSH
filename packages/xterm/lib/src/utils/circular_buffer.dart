import 'dart:math' show max, min;

/// A circular buffer in which elements know their index in the buffer.
class IndexAwareCircularBuffer<T extends IndexedItem> {
  /// Creates a new circular list with the specified [maxLength].
  ///
  /// The backing array starts small and grows as elements come, up to
  /// [maxLength]. It used to be made [maxLength] long at once: a terminal
  /// with "unlimited" scrollback (1,000,000 lines) held two arrays of a
  /// million empty slots, about 16 MB, from the moment its session opened
  /// (found in a review before 4.0).
  IndexAwareCircularBuffer(int maxLength)
      : _maxLength = maxLength,
        _array = List<T?>.filled(min(maxLength, _initialLength), null);

  static const _initialLength = 256;

  /// The number of elements the list holds at most.
  int _maxLength;

  /// The backing array for this list. Its length is at most [maxLength]; it
  /// grows (see [_makeRoom]) until it is that long.
  List<T?> _array;

  /// The length of the backing array, for a test that checks what the list
  /// has allocated.
  int get allocatedLength => _array.length;

  /// Makes the backing array long enough for [length] elements (no longer
  /// than [maxLength]): doubled, the elements laid out from its first slot.
  void _makeRoom(int length) {
    if (length <= _array.length || _array.length >= _maxLength) return;
    var size = _array.length;
    while (size < length) {
      size *= 2;
    }
    if (size > _maxLength) size = _maxLength;
    final newArray = List<T?>.filled(size, null);
    for (var i = 0; i < _length; i++) {
      newArray[i] = _getChild(i);
    }
    _startIndex = 0;
    _array = newArray;
  }

  /// The number of elements in the list. This is always less than or equal to
  /// [maxLength].
  var _length = 0;

  /// The index of the first element in [_array].
  var _startIndex = 0;

  /// The start index of this list, including items that has been dropped in
  /// overflow
  var _absoluteStartIndex = 0;

  /// Gets the cyclic index for the specified regular index. The cyclic index
  /// can then be used on the backing array to get the element associated with
  /// the regular index.
  @pragma('vm:prefer-inline')
  int _getCyclicIndex(int index) {
    return (_startIndex + index) % _array.length;
  }

  /// Removes the element at [index] from the list.
  @pragma('vm:prefer-inline')
  void _dropChild(int index) {
    final cyclicIndex = _getCyclicIndex(index);
    _array[cyclicIndex]?._detach();
    _array[cyclicIndex] = null;
  }

  /// Adds the specified [child] to the list at the specified [index].
  @pragma('vm:prefer-inline')
  void _adoptChild(int index, T child) {
    final cyclicIndex = _getCyclicIndex(index);
    _array[cyclicIndex]?._detach();
    _array[cyclicIndex] = child.._attach(this, index);
  }

  /// Moves the element at [fromIndex] to [toIndex]. Both indexes should be
  /// less than [maxLength].
  @pragma('vm:prefer-inline')
  void _moveChild(int fromIndex, int toIndex) {
    final fromCyclicIndex = _getCyclicIndex(fromIndex);
    final toCyclicIndex = _getCyclicIndex(toIndex);
    _array[toCyclicIndex]?._detach();
    _array[toCyclicIndex] = _array[fromCyclicIndex]?.._move(toIndex);
    _array[fromCyclicIndex] = null;
  }

  /// Gets the element at the specified [index] in the list.
  @pragma('vm:prefer-inline')
  T? _getChild(int index) {
    return _array[_getCyclicIndex(index)];
  }

  /// The number of elements that can be stored in the list.
  int get maxLength {
    return _maxLength;
  }

  /// Sets the number of elements that can be stored in the list. This operation
  /// is relatively expensive, as it requires the backing array to be
  /// reallocated.
  set maxLength(int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, 'value', "maxLength can't be negative!");
    }

    if (value == _maxLength) return;

    // Reconstruct array, starting at index 0. Only transfer values from the
    // indexes 0 to length.
    final newArray = List<T?>.generate(
      max(min(value, _initialLength), min(value, _length)),
      (index) => index < _length ? _getChild(index) : null,
    );

    _startIndex = 0;
    _array = newArray;
    _maxLength = value;
  }

  /// Number of elements in the list.
  int get length {
    return _length;
  }

  /// Iterates over the list and calls [callback] for each element.
  void forEach(void Function(T item) callback) {
    final length = _length;
    for (int i = 0; i < length; i++) {
      callback(_getChild(i)!);
    }
  }

  /// Gets the element at the specified [index] in the list. Throws if the
  /// index is out of bounds.
  T operator [](int index) {
    RangeError.checkValueInInterval(index, 0, length - 1, 'index');
    return _getChild(index)!;
  }

  /// Sets the element at the specified [index] in the list. Throws if the
  /// index is out of bounds.
  operator []=(int index, T value) {
    RangeError.checkValueInInterval(index, 0, length - 1, 'index');
    _adoptChild(index, value);
  }

  /// Removes all elements from the list.
  void clear() {
    for (var i = 0; i < _length; i++) {
      _dropChild(i);
    }
    _startIndex = 0;
    _length = 0;
  }

  /// Adds all elements in [items] to the list.
  void pushAll(Iterable<T> items) {
    for (var element in items) {
      push(element);
    }
  }

  /// Adds [value] to the end of the list. May cause the first element to be
  /// trimmed if the list is full.
  void push(T value) {
    _makeRoom(_length + 1);
    _adoptChild(_length, value);

    if (_length == _array.length) {
      // When the list is full, we trim the first element
      _startIndex++;
      _absoluteStartIndex++;
      if (_startIndex == _array.length) {
        _startIndex = 0;
      }
    } else {
      // When the list is not full, we just increase the length
      _length++;
    }
  }

  /// Removes and returns the last value on the list, throws if the list is
  /// empty.
  T pop() {
    assert(_length > 0, 'Cannot pop from an empty list');
    final result = _getChild(_length - 1);
    _dropChild(_length - 1);
    _length--;
    return result!;
  }

  /// Deletes [count] elements starting at [index], shifting all elements after
  /// [index] to the left.
  void remove(int index, [int count = 1]) {
    if (count > 0) {
      if (index + count >= _length) {
        count = _length - index;
      }
      for (var i = index; i < _length - count; i++) {
        _moveChild(i + count, i);
      }
      for (var i = _length - count; i < _length; i++) {
        _dropChild(i);
      }
      _length -= count;
    }
  }

  /// Inserts [item] at [index], shifting all elements after [index] to the
  /// right. May cause the first element to be trimmed if the list is full.
  void insert(int index, T item) {
    RangeError.checkValueInInterval(index, 0, _length, 'index');

    if (index == _length) {
      return push(item);
    }

    if (index == 0 && _length >= _maxLength) {
      // when something is inserted at index 0 and the list is full then
      // the new value immediately gets removed => nothing changes
      return;
    }

    _makeRoom(_length + 1);

    for (var i = _length - 1; i >= index; i--) {
      _moveChild(i, i + 1);
    }

    _adoptChild(index, item);

    if (_length >= _array.length) {
      _startIndex += 1;
      _absoluteStartIndex += 1;
    } else {
      _length++;
    }
  }

  /// Inserts [items] at [index] in order.
  void insertAll(int index, List<T> items) {
    for (var i = items.length - 1; i >= 0; i--) {
      insert(index, items[i]);
      // when the list is full then we have to move the index down
      // as newly inserted values remove values with a lower index
      if (_length >= _maxLength) {
        index--;
        if (index < 0) {
          return;
        }
      }
    }
  }

  /// Removes the first [count] elements. They leave the list (detached), and
  /// every element after them knows its new index, [count] less than before.
  ///
  /// The start of the list moves; nothing is copied. The start that every
  /// element measures its index from moves with it: moved alone, as it once
  /// was, the list read right and every element in it was wrong about where
  /// it is by [count], and the removed ones still counted as in the list.
  /// That is what `clear` does to a terminal (it removes the scrollback): a
  /// selection made on the screen afterwards stood, and was drawn and copied,
  /// that many rows further down.
  void trimStart(int count) {
    if (count > _length) count = _length;
    if (count <= 0) return;
    for (var i = 0; i < count; i++) {
      _dropChild(i);
    }
    _startIndex += count;
    _startIndex %= _array.length;
    _absoluteStartIndex += count;
    _length -= count;
  }

  /// Replaces all elements in the list with [replacement] (the last
  /// [maxLength] of them, when there are more).
  void replaceWith(List<T> replacement) {
    for (var i = 0; i < _length; i++) {
      _dropChild(i);
    }

    // The replacement is laid out from the first slot. The start moves there
    // BEFORE anything is placed: placed by the old start (which is anywhere
    // once the list has wrapped around) and read by the new one, every
    // element would be found in another's slot, or not at all.
    _startIndex = 0;

    var copyStart = 0;
    if (replacement.length > maxLength) {
      copyStart = replacement.length - maxLength;
    }

    final copyLength = replacement.length - copyStart;
    if (copyLength > _array.length) {
      _array = List<T?>.filled(min(_maxLength, max(copyLength, _array.length * 2)), null);
    }
    for (var i = 0; i < copyLength; i++) {
      _adoptChild(i, replacement[copyStart + i]);
    }

    _length = copyLength;
  }

  /// Moves the elements in [start]..[end] (both inclusive) [count] places
  /// towards the start. The first [count] of them leave the list (detached),
  /// the others keep their identity and know their new index, and the places
  /// freed at the end are filled by [fill]. Elements outside the range are
  /// not touched.
  ///
  /// This is a scroll up inside a region. Assigning `list[i] = list[i + n]`
  /// instead leaves one element in two places for a moment, and overwriting
  /// the second place then detaches it although it is still in the list: its
  /// anchors (a selection, a highlight) stop working.
  void shiftUp(int start, int end, int count, T Function() fill) {
    RangeError.checkValueInInterval(start, 0, _length - 1, 'start');
    RangeError.checkValueInInterval(end, start, _length - 1, 'end');
    if (count <= 0) return;
    final size = end - start + 1;
    if (count > size) count = size;
    for (var i = start; i <= end - count; i++) {
      _moveChild(i + count, i);
    }
    for (var i = end - count + 1; i <= end; i++) {
      _adoptChild(i, fill());
    }
  }

  /// Moves the elements in [start]..[end] (both inclusive) [count] places
  /// towards the end. The last [count] of them leave the list (detached), the
  /// others keep their identity and know their new index, and the places
  /// freed at the start are filled by [fill]. See [shiftUp].
  void shiftDown(int start, int end, int count, T Function() fill) {
    RangeError.checkValueInInterval(start, 0, _length - 1, 'start');
    RangeError.checkValueInInterval(end, start, _length - 1, 'end');
    if (count <= 0) return;
    final size = end - start + 1;
    if (count > size) count = size;
    for (var i = end; i >= start + count; i--) {
      _moveChild(i - count, i);
    }
    for (var i = start; i < start + count; i++) {
      _adoptChild(i, fill());
    }
  }

  /// Replaces the element at [index] with [value] and returns the replaced
  /// item.
  T swap(int index, T value) {
    final result = _getChild(index);
    _adoptChild(index, value);
    return result!;
  }

  /// Whether adding another element would cause the first element to be
  /// trimmed.
  bool get isFull => length == maxLength;

  /// Returns a list containing all elements in the list.
  List<T> toList() {
    return List<T>.generate(length, (index) => this[index]);
  }

  String debugDump() {
    final buffer = StringBuffer();
    buffer.writeln('CircularList:');
    for (var i = 0; i < _length; i++) {
      final child = _getChild(i);
      buffer.writeln('  $i: $child');
    }
    return buffer.toString();
  }
}

mixin IndexedItem {
  IndexAwareCircularBuffer? _owner;

  int? _absoluteIndex;

  /// The index of this item in the buffer. Must only be accessed when
  /// [attached] is true.
  int get index => _absoluteIndex! - _owner!._absoluteStartIndex;

  /// Whether this item is currently stored in a buffer.
  bool get attached => _owner != null;

  /// The buffer this item is stored in, null when it is in none.
  IndexAwareCircularBuffer? get owner => _owner;

  /// Sets the owner and index of this item. This is called by the buffer when
  /// the item is adopted.
  void _attach(IndexAwareCircularBuffer owner, int index) {
    _owner = owner;
    _absoluteIndex = owner._absoluteStartIndex + index;
  }

  /// Marks this item as detached from a buffer. This is called after the item
  /// has been removed from the buffer.
  void _detach() {
    _owner = null;
    _absoluteIndex = null;
  }

  /// Moves this item to [newIndex] in the buffer.
  void _move(int newIndex) {
    assert(attached);
    _absoluteIndex = _owner!._absoluteStartIndex + newIndex;
  }
}
