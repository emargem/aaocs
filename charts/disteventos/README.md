# disteventos

Version: 13.3.1-1
AppVersion: 13.3.1-1

Helm Chart para instalar en un cluster kubernetes el proceso distEventos para el envío de eventos al SG.

## Descripción

Este chart instala el proceso distEventos para un único SDP. En caso de tenerse varios SDP, habra que
instalarlo más de una vez, particularizando la información de conexión a la BD y el *namespace* en que se instala.

### Funcionalidades desplegadas
El chart permite desplegar la funcionalidad distEventos (28-DIST_EVENTOS).
En caso de querere desplegar para otra funcionalidad hay que particularizar en la instalacion los parametros xxxxx.																											 
### Comunicaciones 0MQ

Los procesos desplegados en el cluster de kubernetes se comunican (tanto entre ellos como con otros procesos en la arquitectura
tradicional) usando la librería de comunicaciones 0MQ. Esta librería proporciona distintos tipos de socket, aunque en AltamirA
sólo se emplearán los sockets tipo ROUTER.

Cada proceso tendrá un socket ROUTER que hace de cliente, para enviar peticiones a otros proceso, y otro socket ROUTER
que hace de servidor, para recibir peticiones de otros procesos. Estos sockets son bidireccionales, por lo que las respuestas a
una petición se reciben por el mismo socket por el que se envio dicha petición.

El mecanismo que se ha implementado de comunicación por 0MQ se basa en dos tablas:

* La tabla ZMQC_CONEXIONES contiene la configuración de qué procesos se comunican por 0MQ y con quién. Dicha tabla debe estar configurada
  inicialmente para que DIAMETAR3GPP se comunique por 0MQ con DIST_EVENTOS.
  Dado que el envío
  por 0MQ sólo se hace en procesos cloud, es posible tener unos procesos diametar que se comuniquen con distEventos por 0MQ
  (los que están en cloud) mientras que otros procesos se sigan comunicando por el protocolo SDP_SDP tradicional (los que estén en un BELS normal).
  * ZMQC_CDPROCESO_ORIGEN: Funcionalidad del proceso cliente, por ejemplo DIAMETAR3GPP.
  * ZMQC_CDPROCESO_DESTINO: Funcionalidad del proceso servidor, por ejemplo DIST_EVENTOS
  * ZMQC_NUTIPOENVIO: 0 si el envío es por round-robin. 1 si el envío es serializado a una instancia particular
* La tabla ZMQA_ACTIVOS se actualiza automáticamente con la IP y puerto de los sockets ROUTER de tipo servidor, de aquellos procesos
  que pueden ser destino de una comunicación 0MQ, según la configuración de ZMQC. Esta tabla se monitoriza periódicamente por todos los
  procesos clientes, de forma que puedan detectar si algún proceso nuevo se ha levantado o algún proceso se ha parado.

  Un proceso sólo se registra en esta tabla (los que no se registran no van a recibir peticiones 0MQ) si tiene activo el parámetro de cnf
  ZMQ_REGISTRO_ZMQA.
  Cuando el proceso a registrar en la ZMQA está en una máquina con varios interfaces de red (en un FED o BEL), la IP que se anota en la tabla
  es la primera que cumpla el patrón definido en el parámetro de cnf RED_IP_ZMQ. En este parámetro deberá definirse la red externa por la
  que los procesos en cloud pueden acceder al FED/BEL. Por ejemplo, si esta red es la 10.X.X.X, la variable RED_IP_ZMQ se definirá como "10.".
  Para los procesos que estan en cloud no es necesario definir este parametro RED_IP_ZMQ

### Estructura del pod de distEventos

Todos los contenedores del distEventos ejecutan la misma imagen y, por tanto, tienen la misma estructura:

![Estructura de un POD](estructura.png)

El POD de distEventos se compone de dos contenedores:
* El primero de ellos, de nombre 'proceso' es el distEventos en si. Recibe eventos de los tarificadores en cloud y los envia al SG.
* El segundo es el exportador de métricas y su nombre es 'exporter'. Tiene un script que hace de acumulador, recopilando los
  contadores que genera el distEventos y generando el fichero de metricas. Tambien incluye un mini servidor http (implementado
  como un script), que escucha en el puerto 9100 y devuelve el fichero de métricas cuando se lo pide prometheus.

La comunicación entre estos dos contenedores dentro del pod se realiza mediante ficheros compartidos en un volumen de tipo
emptyDir, que proporciona kubernetes.

### Cifrado de comunicaciones

Es posible (y recomendable) cifrar las comunicaciones de los procesos en cloud con oracle, y con otros procesos de AltamirA.

Para el cifrado de las comunicaciones con otros procesos se usa el mecanismo Curve proporcionado por 0MQ, y se habilita en la
instalación. Es importante tener en cuenta que tanto los procesos en cloud como los procesos tradicionales con los que
éstos se comunican, tienen que tener la misma configuración de cifrado. Es decir, que las variables ZMQ_CIFRADO, ZMQ_CLAVE_PRIVADA
y ZMQ_CLAVE_PUBLICA de DIAMETAR3GPP/SERVERMSIM tienen que tomar los mismos valores que se asignen en el secret zmq-secret y en el
parametro CNF_ZMQ_CIFRADO del chart de Helm.

En el caso de las comunicaciones con oracle, la configuración recomendada es que el servidor tenga un puerto por TCP (por ejemplo el
tradicional 1521) y otro cifrado por TCPS. De esta forma, los procesos tradicionales pueden seguir comunicándose con la BD como siempre
mientras que los procesos en cloud usan un canal cifrado.
El mecanismo de cifrado opera con un wallet en el servidor en el que se registra la clave pública de los clientes. Y un wallet en los clientes
en el que se registra la clave pública del servidor. Este wallet de los clientes se debe proporcionar al cluster de kubernetes en el
secret oracle-secret.

### Almacenamiento persistente

Disteventos necesita un almacenamiento persistente donde ir guardando los ficheros de eventos (enviados y no enviados) en determinados escenarios.
Estos ficheros llevan el nombre de la maquina en la que se crean (hostname del pod). Si un disteventos desaparece y deja algun fichero pendiente
de eventos no enviados, este fichero se lo autoasignara otro disteventos tratandolo como si lo hubiese generado el.

Este almacenamiento persistente se implementa mediante StorageClass, PersistentVolume y PersistentVolumeClaim.

Debe existir un StorageClass y un PersistentVolume asociado a dicho StorageClass.

Desde el POD de disteventos se monta el disco con un PersistentVolumeClaim referenciando al mismo StorageClass.

### Capabilities

En la instalación se incluye un containerSecurityContext por defecto preparado para entornos de pruebas, en los que se requieren
capacidades de depuración. Dicho containerSecurityContext primero desactiva todas las capabilities, y a continuación reactiva las
necesarios para poder usar ping, pstack, gdb y tcpdump:
* NET_ADMIN y NET_RAW: ping
* SYS_PTRACE: gdb y pstack
* SETUID,SETGID,CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,SETUID,SETPCAP,NET_BIND_SERVICE,SYS_CHROOT,MKNOD,AUDIT_WRITE,SETFCA: tcpdump

En entornos de producción en los que se requiera una mayor seguridad, se recomienda instalar particularizado el containerSecurityContext,
de forma que se desactiven todas las capabilities y no se reactive ninguna.

````
containerSecurityContext:
  capabilities:
    drop:
      - all
    add: []
````

### Depuración en tiempo de ejecución

La imagen de disteventos incluye varios mecanismos para la depuración en tiempo de ejecución:
* Se han instalado varias herramientas que pueden ser necesarias a la hora de analizar problemas: ping, curl, tcpdump, pstack, gdb, traceroute, sqlplus
* Si se define en la instalación el parámetro env.SLEEP_AL_TERMINAR, el contenedor no se cerrara aunque se muera el proceso y las sondas darán
OK
* En caso de querer depurar un contenedor que ya está corriendo, se puede crear un fichero vacío /export/manager/DEBUG. Mientras exista este fichero,
  el contenedor no se cerrará aunque se muera el proceso y las sondas darán OK
* Se puede cambiar el nivel de activación de trazas en caliente, simplemente modificando el fichero trazas/Configurar. El proceso relee y reconfigura
  las trazas en la siguiente petición.

### Métricas

Las métricas que genera el proceso distEventos se exportan en el puerto 9100, en la URL /metrics. Son las siguientes:

*  altamira_cnt_dist_eventos_total. Métrica de tipo counter, que se corresponde con los contadores tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de contador, y 'desc' para un nombre descriptivo del contador.  Por ejemplo
   ````
   altamira_cnt_dist_eventos_total{id="0000000",desc="TotalEvenRecibidosDistEventos"}
   ````
*  altamira_alrm_dist_eventos_total. Métrica de tipo counter, que se corresponde con las alarmas tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_alrm_dist_eventos_total{id="ALR0012000",desc="Perdida de Conexion con SG"}
   ````

## Prerequisitos de instalación

* Kubernetes >= 1.14
* El usuario con que se administra el cluster (uso del comando kubectl) debe tener en el PATH la herramienta jq, para el parseo de JSON
* Si se desea usar la funcionalidad de OpenTelemetry, debe tenerse instalado el jaeger-agent. En funcion de que se tenga como un sidecar autoinyectado, como un daemonset o como un servicio, asi se tendran que configurar las variables CNF_OPENTELEMETRY_EXPORTER
* Helm >= 3
* Conexion con la BD del SDP. Debe obtenerse el fichero tnsnames.ora que define las conexiones con la base de datos. Este fichero puede obtenerse de uno de los FED tradicionales. Desde el cluster de kubernetes se debe poder acceder a las direcciones de cada conexion con la BD que se indica en dicho fichero.
* Si se desea conexión cifrada con la BD del SDP
  * En el servidor debe estar levantado un puerto con conexión por TCPS, distinto del habitual usado para comunicaciones no cifradas
  * En el servidor hay que tener un wallet con la clave publica y privada del servidor, y en el que se registra la clave pública del cliente
  * Hay que haber creado un wallet para los clientes, con sus claves pública y privada, y en el que se registra la clave pública del servidor.
    Este wallet se proporciona al cluster de kubernetes en el secret oracle-secret
* En la BD del SDP
  * La tabla ZMQC_CONEXIONES debe existir y estar configurada con las nuevas conexiones 0MQ:
    * DIAMETAR3GPP -> DIST_EVENTOS
* Las imagenes de disteventos y metrics_aa_exporter deben estar subidas al repositorio del cluster. Dichas images se entregan como ficheros tgz.
* Para almacenamiento estático debe estar creado el PVC externamente (y por tanto tambien el StorageClass y el PV) y para dinámico debe estar creado el StorageClass utilizado al desplegar el chart (pvc.storageClassName)  (* dependiendo del entorno utilizado puede ser necesario también crear el PersistentVolume asociado a ese StorageClass)

## Instalacion
El chart se entrega comprimido en un fichero tgz. Si se desea, seria posible subir dicho fichero tgz a un servidor HTTP que haga de repositorio de charts e instalarlo desde alli. La otra posibilidad es instalar directamente desde el fichero, que es la que se detalla en este documento

* Como primer paso, generar un fichero con los values sobre el que podremos modificar los parametros que queramos
	````
	helm show values disteventos-13.3.1-1.tgz > values-disteventos-13.3.1-1.yaml
	````
* Modificar el fichero generado, particularizando los parametros que nos interesan.
Si no nos interesa modificar algún parámetro, lo podemos eliminar. Y si no queremos cambiar ningún parámetro de un objeto, podemos borrar el objeto completo. Los parámetros mas relevantes a revisar son los siguientes
  * replicaCount
  * NIVEL_TRAZAS
  * env.CNF_OPENTELEMETRY_EXPORTER_TIPO
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * **image.repository**: Hay que definirlo obligatoriamente
  * **exporterImage.repository**: Hay que definirlo obligatoriamente
  * **reloadMonitorImage.repository**: Hay que definirlo obligatoriamente
  * podAnnotations.prometheus
  * service
  * autoscaling
  * pvc
* Instalar el chart con las particularizaciones que se hayan definido en el fichero *values-disteventos.yaml*.  
El \<namespace\> se recomienda que incluya el id del SDP con que se comunican los procesos (por ejemplo aa-ocs-sdp1). Como \<release name\> se usa uno descriptivo de lo que se esta instalando, como *distev*
	````
	helm install -n <namespace> disteventos-13.3.1-1.tgz -f values-disteventos-13.3.1-1.yaml
	````
* Verificar que se ha instalado y que lleva los parametros que hemos particularizado
	````
	helm list -n <namespace>
	helm -n <namespace> get values <release name>
	````
	
## Configuración

A continuación se detallan todos los parámetros pertenecientes al fichero *values.yaml*, y que por tanto pueden particularizarse en la instalación

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| autoscaling.enabled | bool | `true` | Activacion del HPA  |
| autoscaling.maxReplicas | int | `5` | Numero maximo de instancias  |
| autoscaling.minReplicas | int | `1` | Numero minimo de instancias  |
| autoscaling.targetCPUUtilizationValue | string | `"700m"` | Umbral de consumo de CPU de una instancia para que el HPA escale En API autoscaling/v1 el valor debe ser en porcentaje (70 = 70% de los cores reservados. p.ej con resources.requests.cpu=1 70% es el 70% de una CPU)  En API autoscaling/v2beta2 el valor debe ser en unidades de cores (700m son 700 milicores de 1 CPU = 70% de una CPU) |
| autoscaling.targetCPUUtilizationValuev1 | int | `70` |  |
| autoscaling.versionAPIv1 | bool | `true` |  |
| disteventos.enabled | bool | `true` | Activacion de la funcionalidad  |
| disteventos.funcionalidad | string | `"DIST_EVENTOS"` | Nombre de la funcionalidad que se esta desplegando  |
| disteventos.funcionalidad_id | int | `28` | Identificador (tabla AD) de la funcionalidad que se esta desplegando |
| disteventos.instanciaCount | int | `1` | Numero de instancias del distEventos que se levantan dentro del POD |
| disteventos.replicaCount | int | `1` | Numero de instancias del distEventos que se levantan  |
| env.CELULA | object | `{"value":"1"}` | Celula en la que se despliega el chart. Por defecto celula 1. |
| env.CNF_OPENTELEMETRY_EXPORTER_HOST | object | `{"value":"jaeger-agent.jaeger"}` | Host donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_PORT) Si es por UDP, se suele enviar a localhots o a un DaemonSet (indicando en CNF_OPENTELEMETRY_EXPORTER_HOST status.hostIP) Si es por HTTP se pone la direccion del jaeger agent, por ejemplo jaeger-agent.jaeger |
| env.CNF_OPENTELEMETRY_EXPORTER_PORT | object | `{"value":"6831"}` | Puerto donde se envian los intervalos de OpenTelemetry (en conjuntcion con CNF_OPENTELEMETRY_EXPORTER_HOST) |
| env.CNF_OPENTELEMETRY_EXPORTER_TIPO | object | `{"value":"0"}` | Tipo de exporter de OpenTelemetry.  0-Ninguno, 1-Logs, 2-JaegerUDP, 3-JaegerHTTP |
| env.CNF_ZMQ_CIFRADO | object | `{"value":"1"}` | Uso de cifrado en las conexiones 0MQ (las claves deben proporcionarse en el zmq-secret). Los procesos    de FED y BELS tienen que tener la misma configuración |
| env.CNF_ZMQ_SOLO_MISMA_CELULA | object | `{"value":"0"}` | Variable para forzar que los procesos se comuniquen solo con funcionalides de la misma celula. Por defecto 0 para evitarlo. |
| env.DATABASE_ENCRYPT | object | ... | Variable para definir si la comunicacion con la BD se hace encriptada o no. Valor 0 indica no encriptada, valor 1 encriptada. |
| env.NIVEL_TRAZAS | object | `{"value":"0"}` | Nivel de trazas del proceso: 0-Todas. 1-Solo de error e informativas |
| env.SERVICIO | object | `{"value":"PREPAGO"}` | Servicio AA para el que se despliega este chart (Etiqueta e Identificador) |
| env.SERVICIO_ID.value | string | `"1"` |  |
| env.SLEEP_AL_TERMINAR | object | `{"value":"0"}` | Variable para definir el número de segundos que se mantiene vivo el pod una vez que se ha muerto el proceso. Util para depuracion |
| exporterImage.repository | string | `"zape-k8s-dockreg:5000/metrics_aa_exporter"` | Repositorio de donde bajar el contenedor del exportador de metricas, para llevar los contadores de diameterdatos a prometheus |
| image.repository | string | `"zape-k8s-dockreg:5000/disteventos"` | Repositorio de donde bajar el contenedor del diameterdatos (version en Chart.yaml/appVersion) |
| podAnnotations."prometheus.io/port" | string | `"9100"` | Puerto donde se sirven las metricas |
| podAnnotations."prometheus.io/scrape" | string | `"true"` | Anotacion para indicar a prometheus que debe recopilar metricas de estos pods |
| podSecurityContext | string | `nil` |  |
| pvc.dinamico.accessMode | string | `"ReadWriteOnce"` |  |
| pvc.dinamico.retain | bool | `true` |  |
| pvc.dinamico.size | string | `"1Gi"` |  |
| pvc.dinamico.storageClassName | string | `"standard"` |  |
| pvc.pvcExistente | string | `nil` |  |
| resources | object | `{"limits":{"cpu":1},"requests":{"cpu":1}}` | Recursos de CPU. Limite y requests. Son valores aplicados unicamente a los contenedores proceso  Es necesario su definicion para el uso de HPA con autoscaling/v1 |
| securityContext.capabilities.add[0] | string | `"SYS_PTRACE"` |  |
| securityContext.capabilities.add[10] | string | `"SETUID"` |  |
| securityContext.capabilities.add[11] | string | `"SETPCAP"` |  |
| securityContext.capabilities.add[12] | string | `"NET_BIND_SERVICE"` |  |
| securityContext.capabilities.add[13] | string | `"SYS_CHROOT"` |  |
| securityContext.capabilities.add[14] | string | `"MKNOD"` |  |
| securityContext.capabilities.add[15] | string | `"AUDIT_WRITE"` |  |
| securityContext.capabilities.add[16] | string | `"SETFCAP"` |  |
| securityContext.capabilities.add[1] | string | `"NET_ADMIN"` |  |
| securityContext.capabilities.add[2] | string | `"NET_RAW"` |  |
| securityContext.capabilities.add[3] | string | `"SETUID"` |  |
| securityContext.capabilities.add[4] | string | `"SETGID"` |  |
| securityContext.capabilities.add[5] | string | `"CHOWN"` |  |
| securityContext.capabilities.add[6] | string | `"DAC_OVERRIDE"` |  |
| securityContext.capabilities.add[7] | string | `"FOWNER"` |  |
| securityContext.capabilities.add[8] | string | `"FSETID"` |  |
| securityContext.capabilities.add[9] | string | `"KILL"` |  |
| securityContext.capabilities.drop[0] | string | `"all"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |

