"""
Mirror of MCGroupElements / MCExpandedFrames from port/tweak/Tweak.x, used to
check the row packing and the "single row only" idempotency guard without an
iOS device.
"""

ELEMENTS_PER_ROW = 4


def group_elements(widths, row_count):
    """Greedy packing: each element goes into the first row that still has room."""
    groups = [[] for _ in range(row_count)]
    used = [0] * row_count
    for index, width in enumerate(widths):
        for row in range(row_count):
            if used[row] + width <= ELEMENTS_PER_ROW:
                used[row] += width
                groups[row].append(index)
                break
    return groups


def is_single_row(ys, epsilon=0.5):
    if not ys:
        return False
    base = ys[0]
    return all(abs(y - base) <= epsilon for y in ys)


def expand(widths, row_count, container_height=200.0, spacing=10.0, ys=None):
    """Returns (rows, frames) where frames maps element index -> (y, height)."""
    if ys is None:
        ys = [0.0] * len(widths)

    single_row = is_single_row(ys)
    if row_count <= 1 or not single_row:
        return None, {i: (y, 0.0) for i, y in enumerate(ys)}

    row_height = (container_height - spacing * (row_count - 1)) / row_count
    groups = group_elements(widths, row_count)

    frames = {}
    for row_index, group in enumerate(groups):
        if not group:
            continue
        y = row_index * (row_height + spacing)
        for element in group:
            frames[element] = (y, row_height)
    # never drop an element
    for index, y in enumerate(ys):
        frames.setdefault(index, (y, 0.0))
    return groups, frames


def check(name, widths, row_count, expect_rows, expect_single_unchanged=False, ys=None):
    groups, frames = expand(widths, row_count, ys=ys)
    if expect_single_unchanged:
        ok = groups is None
    else:
        ok = groups == expect_rows
    ys_after = [frames[i][0] for i in sorted(frames)]
    overlaps = False
    if groups is not None:
        # rows must not overlap vertically
        spans = sorted({(round(frames[g[0]][0], 3), round(frames[g[0]][1], 3)) for g in expect_rows if g})
        for (y1, h1), (y2, h2) in zip(spans, spans[1:]):
            if y1 + h1 > y2 + 1e-9:
                overlaps = True
    print(f"{'PASS' if ok and not overlaps else 'FAIL'}  {name}: groups={groups} ys={[round(y,1) for y in ys_after]}")
    return ok and not overlaps


results = [
    check("2 elements / 2 rows -> one row used", [2, 2], 2, [[0, 1], []]),
    check("3 elements / 2 rows -> wraps", [2, 2, 2], 2, [[0, 1], [2]]),
    check("2 full-width / 2 rows -> one each", [4, 4], 2, [[0], [1]]),
    check("4 narrow / 2 rows -> all fit one row", [1, 1, 1, 1], 2, [[0, 1, 2, 3], []]),
    check("4 medium / 3 rows", [2, 2, 2, 2], 3, [[0, 1], [2, 3], []]),
    check("rows=1 -> untouched", [2, 2, 2], 1, None, expect_single_unchanged=True),
    check("already 2 rows -> untouched (idempotent)", [2, 2, 2], 2, None,
          expect_single_unchanged=True, ys=[0.0, 0.0, 105.0]),
    check("sidebar (vertical) -> untouched", [2, 2, 2], 2, None,
          expect_single_unchanged=True, ys=[0.0, 105.0, 210.0]),
]

print()
print("all checks passed" if all(results) else "FAILURES PRESENT")
