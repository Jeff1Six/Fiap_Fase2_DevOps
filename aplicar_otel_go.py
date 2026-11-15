"""Aplica instrumentacao OpenTelemetry nos servicos Go do ToggleMaster.
Execute da raiz do repositorio: py -3 .\aplicar_otel_go.py
Base: arquivos do repositorio publico Jeff1Six/Fiap_Fase2_DevOps (main).
Faz validacoes de marcadores antes de gravar e nao altera os servicos Python.
"""
from pathlib import Path

root = Path.cwd()
services = ("auth-service", "evaluation-service")
for service in services:
    if not (root / service / "main.go").exists():
        raise SystemExit(f"ERRO: execute na raiz do repositorio. Ausente: {service}/main.go")
    if "shutdownOTel" in (root / service / "main.go").read_text(encoding="utf-8-sig"):
        raise SystemExit(f"Instrumentacao ja aplicada em {service}; confira git diff em vez de executar novamente.")

def read(p):
    return p.read_text(encoding="utf-8-sig")

def replace_one(source, old, new, path):
    count = source.count(old)
    if count == 0 and new in source:
        return source
    if count != 1:
        raise ValueError(f"{path}: esperado um marcador, encontrados {count}: {old[:100]!r}")
    return source.replace(old, new, 1)

# Apenas monta as alteracoes em memoria. Se faltar algum marcador, nao grava nada.
changes = {}
for service in services:
    path = root / service / "main.go"
    content = read(path)
    content = replace_one(content, 'import (\n', 'import (\n\t"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"\n', path)
    if service == "auth-service":
        content = replace_one(content, 'import (\n', 'import (\n\t"context"\n', path)
    content = replace_one(
        content,
        '_ = godotenv.Load()',
        '_ = godotenv.Load()\n\n\tshutdownOTel, err := iniciarOpenTelemetry("' + service + '")\n\tif err != nil {\n\t\tlog.Fatalf("Erro ao iniciar OpenTelemetry: %v", err)\n\t}\n\tdefer func() {\n\t\tif err := shutdownOTel(context.Background()); err != nil {\n\t\t\tlog.Printf("Erro ao finalizar OpenTelemetry: %v", err)\n\t\t}\n\t}()',
        path,
    )
    content = replace_one(content, 'Handler:      mux,', 'Handler:      otelhttp.NewHandler(mux, "' + service + '"),', path)
    if service == "evaluation-service":
        content = replace_one(content,
            'httpClient := &http.Client{\n\t\tTimeout: 5 * time.Second,',
            'httpClient := &http.Client{\n\t\tTimeout: 5 * time.Second,\n\t\tTransport: otelhttp.NewTransport(http.DefaultTransport),', path)
    changes[path] = content

path = root / "evaluation-service" / "handlers.go"
content = read(path)
content = replace_one(content, 'a.getDecision(userID, flagName)', 'a.getDecision(r.Context(), userID, flagName)', path)
changes[path] = content

path = root / "evaluation-service" / "evaluator.go"
content = read(path)
content = replace_one(content, 'import (\n', 'import (\n\t"context"\n', path)
replacements = [
    ('getDecision(userID, flagName string)', 'getDecision(requestCtx context.Context, userID, flagName string)'),
    ('a.getCombinedFlagInfo(flagName)', 'a.getCombinedFlagInfo(requestCtx, flagName)'),
    ('getCombinedFlagInfo(flagName string)', 'getCombinedFlagInfo(requestCtx context.Context, flagName string)'),
    ('a.RedisClient.Get(ctx, cacheKey)', 'a.RedisClient.Get(requestCtx, cacheKey)'),
    ('a.RedisClient.Set(ctx, cacheKey', 'a.RedisClient.Set(requestCtx, cacheKey'),
    ('a.fetchFromServices(flagName)', 'a.fetchFromServices(requestCtx, flagName)'),
    ('fetchFromServices(flagName string)', 'fetchFromServices(requestCtx context.Context, flagName string)'),
    ('a.fetchFlag(flagName)', 'a.fetchFlag(requestCtx, flagName)'),
    ('a.fetchRule(flagName)', 'a.fetchRule(requestCtx, flagName)'),
    ('fetchFlag(flagName string)', 'fetchFlag(requestCtx context.Context, flagName string)'),
    ('fetchRule(flagName string)', 'fetchRule(requestCtx context.Context, flagName string)'),
]
for old, new in replacements:
    content = replace_one(content, old, new, path)
# Existem exatamente duas requisicoes, uma para cada servico.
old = 'req, _ := http.NewRequest("GET", url, nil)'
if content.count(old) != 2:
    raise ValueError(f"{path}: esperado 2 requisicoes HTTP, encontrado {content.count(old)}")
content = content.replace(old,
    'req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, url, nil)\n\tif err != nil {\n\t\treturn nil, fmt.Errorf("erro ao criar requisicao HTTP: %w", err)\n\t}')
changes[path] = content

template = read(Path(__file__).resolve().parent / "otel_setup.go")
for service in services:
    path = root / service / "otel_setup.go"
    if path.exists() and read(path) != template:
        raise ValueError(f"{path}: ja existe com conteudo diferente. Nao sera sobrescrito.")
    changes[path] = template

for path, value in changes.items():
    path.write_text(value, encoding="utf-8", newline="\n")
    print(f"OK: {path.relative_to(root)}")
print("Arquivos Go preparados. Agora execute .\\validar_otel_go.ps1")
