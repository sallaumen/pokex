# No CI (runner de 2 núcleos) os testes de visão que mastigam as fixtures de
# captura real levam 3-6× o tempo do Apple Silicon local — três módulos já
# estouraram os 60s default lá, um por rodada, em whack-a-mole. A folga vale só
# no CI: local, um teste que passar de 60s continua sendo um travamento a
# investigar, não um teste lento a tolerar.
timeout = if System.get_env("CI"), do: 300_000, else: 60_000
ExUnit.start(timeout: timeout)
