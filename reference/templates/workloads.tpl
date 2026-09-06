apiVersion: apps/v1
kind: Deployment
metadata:
  name: telemetry-ingest
  labels: {app.kubernetes.io/name: telemetry-ingest}
  annotations:
    jouren.io/source-revision: {{ .Values.ingest.sourceRevision | quote }}
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: telemetry-ingest}
  template:
    metadata:
      labels: {app.kubernetes.io/name: telemetry-ingest}
      annotations:
        jouren.io/source-revision: {{ .Values.ingest.sourceRevision | quote }}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: telemetry-ingest
          image: {{ .Values.ingest.image | quote }}
          ports: [{name: http, containerPort: 8080}]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}
          resources:
            requests: {cpu: 100m, memory: {{ .Values.ingest.memory | quote }}}
            limits: {memory: {{ .Values.ingest.memory | quote }}}
          env:
            - {name: INGEST_LISTEN, value: "0.0.0.0:8080"}
            - {name: INGEST_DB_HOST, value: {{ .Values.ingest.databaseHost | quote }}}
            - {name: INGEST_DB_NAME, value: telemetry}
            - {name: INGEST_DB_USER, value: telemetry}
            - name: INGEST_DB_PASSWORD
              valueFrom: {secretKeyRef: {name: {{ .Values.database.existingSecret | quote }}, key: password}}
            - {name: INGEST_DB_POOL_MAX, value: "5"}
            - {name: INGEST_CACHE_PER_SENSOR, value: "500"}
            - {name: INGEST_WARM_ON_START, value: "true"}
            - {name: INGEST_RETENTION_HOURS, value: "1"}
            - {name: OTEL_SERVICE_NAME, value: telemetry-ingest}
            - {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.telemetry.svc.cluster.local:4318"}
            - {name: K8S_POD, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "k8s.namespace.name=telemetry,k8s.pod.name=$(K8S_POD),k8s.deployment.name=telemetry-ingest"
          readinessProbe: {httpGet: {path: /readyz, port: http}, periodSeconds: 5}
          livenessProbe: {httpGet: {path: /healthz, port: http}, periodSeconds: 10}
---
apiVersion: v1
kind: Service
metadata: {name: telemetry-ingest}
spec:
  selector: {app.kubernetes.io/name: telemetry-ingest}
  ports: [{name: http, port: 8080, targetPort: http}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fleet
  labels: {app.kubernetes.io/name: fleet}
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: fleet}
  template:
    metadata:
      labels: {app.kubernetes.io/name: fleet}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: fleet
          image: {{ .Values.fleet.image | quote }}
          ports: [{name: admin, containerPort: 8081}]
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits: {memory: 128Mi}
          env:
            - {name: FLEET_TARGET, value: "http://telemetry-ingest.telemetry.svc.cluster.local:8080"}
            - {name: FLEET_ADMIN_LISTEN, value: "0.0.0.0:8081"}
            - {name: FLEET_SENSORS, value: "2000"}
            - {name: FLEET_BATCH, value: "50"}
            - {name: FLEET_POSTS_PER_SEC, value: "40"}
            - {name: FLEET_QUERIES_PER_SEC, value: "5"}
            - {name: FLEET_WARMUP_POSTS_PER_SEC, value: "80"}
            - {name: FLEET_WARMUP_SECS, value: "300"}
            - {name: FLEET_MODE, value: stable}
          readinessProbe: {httpGet: {path: /healthz, port: admin}, periodSeconds: 5}
---
apiVersion: v1
kind: Service
metadata: {name: fleet}
spec:
  selector: {app.kubernetes.io/name: fleet}
  ports: [{name: admin, port: 8081, targetPort: admin}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: telemetry-db
spec:
  serviceName: telemetry-db
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: telemetry-db}
  template:
    metadata:
      labels: {app.kubernetes.io/name: telemetry-db}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: postgres
          image: {{ .Values.database.image | quote }}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          args: ["-c", "shared_buffers=64MB", "-c", "max_connections=30", "-c", "work_mem=2MB"]
          env:
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
            - {name: POSTGRES_DB, value: telemetry}
            - {name: POSTGRES_USER, value: telemetry}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: {{ .Values.database.existingSecret | quote }}, key: password}}
          ports: [{name: postgres, containerPort: 5432}]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 512Mi}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
          readinessProbe: {exec: {command: [pg_isready, -U, telemetry, -d, telemetry]}, periodSeconds: 5}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: local-path
        resources:
          requests: {storage: {{ .Values.database.storage | quote }}}
---
apiVersion: v1
kind: Service
metadata: {name: telemetry-db}
spec:
  clusterIP: None
  selector: {app.kubernetes.io/name: telemetry-db}
  ports: [{name: postgres, port: 5432, targetPort: postgres}]
