from pyomo.environ import *

solver = SolverFactory("cplex")

print("Solver available:", solver.available())