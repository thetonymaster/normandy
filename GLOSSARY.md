# Normandy

Normandy is a library for building AI agents: an agent takes user input, works with a model and tools, and answers in a declared shape.

## Language

### Turns

**Turn**:
One user input taken through the model and tools to its answer or its failure. It has its own id, and every message it adds is stored under that id.
_Avoid_: Run, exchange, step

**Run**:
One execution of a turn by an agent, from the call that starts or resumes it until the turn answers, fails, stops to wait for approval, or is cut off by a crash. A turn that waits or crashes takes more than one run.
_Avoid_: Turn, execution, attempt

**Tool round**:
One model response that calls tools, together with those tools' results.
_Avoid_: Iteration, tool batch, loop

**Iteration**:
One unit of a turn's tool budget. A tool round spends one, and so does sending a paused response back to the model to continue.
_Avoid_: Round, step, loop

**Final call**:
The model call that must answer without tools, made when a turn's iterations run out or when its answer is asked for again. It spends no iteration.
_Avoid_: Last call, closing call
