"""Prints the operators that ExecuTorch programs run outside their delegates, as the comma-separated
list EXECUTORCH_SELECT_OPS_LIST takes (ns::name.overload). Methods are listed on stderr.

usage: python list_ops.py <.pte> [<.pte> ...]
"""
import sys

from executorch.exir._serialize._program import deserialize_pte_binary

ops = set()
for path in sys.argv[1:]:
    with open(path, "rb") as f:
        pte = deserialize_pte_binary(f.read())
    program = getattr(pte, "program", pte)
    for plan in program.execution_plan:
        names = {f"{o.name}.{o.overload}" if o.overload else o.name for o in plan.operators}
        delegates = sorted({d.id for d in plan.delegates})
        print(f"{path}: {plan.name}: delegates {delegates}, ops {sorted(names)}", file=sys.stderr)
        ops |= names
if not ops:
    sys.exit("no operators outside the delegates")
print(",".join(sorted(ops)))
