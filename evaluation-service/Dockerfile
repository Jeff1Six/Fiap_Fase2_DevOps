FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o evaluation-service .

FROM alpine:3.20

WORKDIR /app

RUN adduser -D appuser

COPY --from=builder /app/evaluation-service .

USER appuser

EXPOSE 8004

CMD ["./evaluation-service"]