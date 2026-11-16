package main

import (
	"context"
	"log"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
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
	// Exportacao OTLP de metricas, usando a mesma identidade dos traces.
	metricEndpoint := "http://togglemaster-otel-opentelemetry-collector.monitoring.svc.cluster.local:4318/v1/metrics"
	if os.Getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		if err := os.Setenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", metricEndpoint); err != nil {
			_ = provider.Shutdown(ctx)
			return nil, err
		}
	}
	metricExporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		_ = provider.Shutdown(ctx)
		return nil, err
	}
	meterProvider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(resource.NewWithAttributes("",
			attribute.String("service.name", serviceName),
			attribute.String("service.namespace", "togglemaster"),
		)),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter, sdkmetric.WithInterval(15*time.Second))),
	)
	otel.SetMeterProvider(meterProvider)

	// Metrica diagnostica para validar a chegada de metricas no New Relic.
	startupCounter, err := otel.Meter("togglemaster.otel").Int64Counter("togglemaster.otel.startups", metric.WithUnit("1"))
	if err != nil {
		_ = meterProvider.Shutdown(ctx)
		_ = provider.Shutdown(ctx)
		return nil, err
	}
	startupCounter.Add(context.Background(), 1)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))
	log.Printf("OpenTelemetry ativado: %s", serviceName)
	return func(ctx context.Context) error {
		metricErr := meterProvider.Shutdown(ctx)
		traceErr := provider.Shutdown(ctx)
		if metricErr != nil {
			return metricErr
		}
		return traceErr
	}, nil
}
