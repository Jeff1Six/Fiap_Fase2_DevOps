package main

import (
    "context"
    "log"
    "os"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// Inicializa o tracing HTTP/OTLP; a chave New Relic permanece apenas no Collector.
func iniciarOpenTelemetry(serviceName string) (func(context.Context) error, error) {
    const collector = "http://togglemaster-otel-opentelemetry-collector.monitoring.svc.cluster.local:4318/v1/traces"
    if os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
        if err := os.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", collector); err != nil {
            return nil, err
        }
    }

    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    exporter, err := otlptracehttp.New(ctx)
    if err != nil {
        return nil, err
    }

    provider := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(resource.NewWithAttributes("", attribute.String("service.name", serviceName))),
    )
    otel.SetTracerProvider(provider)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))
    log.Printf("OpenTelemetry ativado: %s", serviceName)
    return provider.Shutdown, nil
}
