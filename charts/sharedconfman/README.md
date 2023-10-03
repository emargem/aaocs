# sharedconfman

Version: 13.3.1-0
AppVersion: 13.3.1-0

Helm Chart para instalar en un cluster kubernetes el proceso de BELS que gestiona la memoria compartida (sharedconfman)

## Descripción

Este chart instala el sharedconfman para un único SDP. En caso de tenerse varios SDP, habra que
instalarlos más de una vez, particularizando la información de conexión a la BD y el *namespace* en que se instala.

Si no se usa memoria compartida, no es necesario instalarlo

De igual modo, si se usa memoria compartida a nivel de POD, tampoco es necesario instalar este chart.

Sólo es necesario en caso de usarse memoria compartida a nivel de nodo worker (ver *memoriaCompartida* y *scmEnPod* de la
instalación de diametar)

### Funcionalidades desplegadas

El chart permite desplegar una funcionalidad de sharedconfman (por defecto 150-SHAREDCONFMAN)
En caso de querer desplegar para otra funcionalidad sólo hay que particularizar en la instalacion los parametros
*sharedconfman.funcionalidad* y *sharedconfman.funcionalidadId*.

### Comunicaciones 0MQ

Los procesos desplegados en el cluster de kubernetes se comunican (tanto entre ellos como con otros procesos en la arquitectura
tradicional) usando la librería de comunicaciones 0MQ. Esta librería proporciona distintos tipos de socket, aunque en AltamirA
sólo se emplearán los sockets tipo ROUTER.

Cada proceso tendrá un socket ROUTER que hace de cliente, para enviar peticiones a otros proceso, y otro socket ROUTER
que hace de servidor, para recibir peticiones de otros procesos. Estos sockets son bidireccionales, por lo que las respuestas a
una petición se reciben por el mismo socket por el que se envio dicha petición.

El mecanismo que se ha implementado de comunicación por 0MQ se basa en dos tablas:

* La tabla ZMQC_CONEXIONES contiene la configuración de qué procesos se comunican por 0MQ y con quién. En el caso del
  sharedconfman, que no recibe peticiones de ningun cliente, ni envía peticiones a ningún servidor, no es necesaria
  ninguna configuración especial.
  * ZMQC_CDPROCESO_ORIGEN: Funcionalidad del proceso cliente, por ejemplo DIAMETAR3GPP.
  * ZMQC_CDPROCESO_DESTINO: Funcionalidad del proceso servidor, por ejemplo GENCDR
  * ZMQC_NUTIPOENVIO: 0 si el envío es por round-robin. 1 si el envío es serializado a una instancia particular, 2 si el envío es local
    a  la instancia equivalente
  * ZMQC_NUDIRCONEXION: 0 si la conexión se abre de cliente a servidor, 1 si se abre de servidor a cliente
* La tabla ZMQA_ACTIVOS se actualiza automáticamente con la IP y puerto de los sockets ROUTER de tipo servidor, de aquellos procesos
  que pueden ser destino de una comunicación 0MQ, según la configuración de ZMQC. Esta tabla se monitoriza periódicamente por todos los
  procesos clientes, de forma que puedan detectar si algún proceso nuevo se ha levantado o algún proceso se ha parado.

  Un proceso sólo se registra en esta tabla (los que no se registran no van a recibir peticiones 0MQ) si tiene activo el parámetro de cnf
  ZMQ_REGISTRO_ZMQA.
  Cuando el proceso a registrar en la ZMQA está en una máquina con varios interfaces de red (en un FED o BEL), la IP que se anota en la tabla
  es la primera que cumpla el patrón definido en el parámetro de cnf RED_IP_ZMQ. En este parámetro deberá definirse la red externa por la
  que los procesos en cloud pueden acceder al FED/BEL. Por ejemplo, si esta red es la 10.X.X.X, la variable RED_IP_ZMQ se definirá como "10.".
  Para los procesos que estan en cloud no es necesario definir este parametro RED_IP_ZMQ

### Memoria compartida

Diametar acceder a ciertas tablas de configuración en memoria compartida. Para ello, además de estar habilitado a nivel de BD, debe configurarse
en el propio cnf del diametar con el parámetro _memoriaCompartida_.

Si en diametar se configura que la memoria se comparta entre PODs del mismo nodos worker (parámetro del diametar _scmEnPod_ desactivado y _memoriaCompartida_ activado), entonces
es necesario instalar este chart con el sharedconfman.  En este caso, la memoria compartida del nodo worker (directorio /dev/shm) se
monta tanto en los PODs del diametar con en los PODs del sharedconfman como /dev/shm

![Comparticion de memoria en el pod](comparteWorker.png)

Si no se desea memoria compartida, o se comparte dentro del POD, no es necesario instalar este chart con un sharedconfman
independiente.

### Estructura del pod sharedconfman

Sharedconfman se despliega como un Daemonset, con un POD en cada nodo worker. En este proceso no se puede variar el número de réplicas
ni el número de instancias dentro de cada una.

![Estructura de un POD](estructura.png)

Cada POD de sharedconfman se compone de:
* 1 contenedor, de nombre 'proceso', con el sharedconfman
* 1 exportador de métricas cuyo nombre es 'exporter'. Tiene un script que hace de acumulador, recopilando los contadores que generan diametar y sharedconfman, y generando el fichero de metricas. Tambien incluye un mini servidor http (implementado como un script), que escucha en el puerto 9100 y devuelve el fichero de métricas cuando se lo pide prometheus.

La comunicación entre el exporter y los otros procesos del pod se realiza mediante ficheros compartidos en un volumen de tipo
emptyDir, que proporciona kubernetes.

### Cifrado de comunicaciones

Es posible (y recomendable) cifrar las comunicaciones de los procesos en cloud con oracle, y con otros procesos de AltamirA.

Para el cifrado de las comunicaciones con otros procesos se usa el mecanismo Curve proporcionado por 0MQ, y se habilita en la
instalación. Es importante tener en cuenta que tanto los procesos en cloud como los procesos tradicionales con los que
éstos se comunican, tienen que tener la misma configuración de cifrado. Es decir, que las variables ZMQ_CIFRADO, ZMQ_CLAVE_PRIVADA
y ZMQ_CLAVE_PUBLICA tienen que tomar los mismos valores para los procesos FED/BELS que los que se asignen en el secret zmq-secret y en el
parametro CNF_ZMQ_CIFRADO del chart de Helm.

En el caso de las comunicaciones con oracle, la configuración recomendada es que el servidor tenga un puerto por TCP (por ejemplo el
tradicional 1521) y otro cifrado por TCPS. De esta forma, los procesos tradicionales pueden seguir comunicándose con la BD como siempre
mientras que los procesos en cloud usan un canal cifrado.
El mecanismo de cifrado opera con un wallet en el servidor en el que se registra la clave pública de los clientes. Y un wallet en los clientes
en el que se registra la clave pública del servidor. Este wallet de los clientes se debe proporcionar al cluster de kubernetes en el
secret oracle-secret.

### Limitación de recursos

Al instalar deben particularizarse los límites (resources del fichero values) de sharedconfman
Se deben configurar tanto los límites de cpu como los de memoria. Por ejemplo:
````
resources:
  limits:
    cpu: "1000m"
    memory: "200Mi"
````

1000m de cpu es una CPU. Dado que los procesos de altamira son mono-thread, no tiene sentido definir límites mayores que dicho valor.
1Mi de memoria es 1024*1024 bytes. El límite que se defina para la memoria debe ser un valor que el proceso no vaya a alcanzar nunca
en un funcionamiento normal, ya que si lo alcanza se le reiniciará.

Si se desea, además de los límites se puede definir la cantidad reservada (requests). En caso de definirse limits; pero no requests, se
considera que el valor de requests es identico al de limits. Cuando todos los contenedores de un POD tienen los mismos valores de requests y limits
se considera que dicho POD tiene una calidad de servicio garantizada y no se le reiniciara en escenarios de sobrecarga del nodo.

El valor de requests se utiliza para determinar en que nodo se despliega el pod. Además, el valor de requests.memory se usa también para
calcular el orden de eliminación de procesos en escenarios de sobrecarga del nodo. La probabilidad de que un proceso sea matado en estos
escenarios es mayor cuanto menor sea su resources.requests.memory.

Por tanto, la recomendación es que se definan limits y requests superiores a lo que pueda necesitar el proceso en un funcionamiento normal.
En el caso de procesos que sea particularmente importante que no sean reiniciados se debe definir sólo limits (que es equivalente a definir
request y limits con el mismo valor).

### Capabilities

En la instalación se incluye un containerSecurityContext por defecto preparado para entornos de pruebas, en los que se requieren
capacidades de depuración. Dicho containerSecurityContext primero desactiva todas las capabilities, y a continuación reactiva las
necesarios para poder usar ping, pstack, gdb y tcpdump:
* NET_ADMIN y NET_RAW: ping
* SYS_PTRACE: gdb y pstack
* SETUID,SETGID,CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,SETUID,SETPCAP,NET_BIND_SERVICE,SYS_CHROOT,MKNOD,AUDIT_WRITE,SETFCAP: tcpdump

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

La imagen de sharedconfman incluye varios mecanismos para la depuración en tiempo de ejecución:
* Se han instalado varias herramientas que pueden ser necesarias a la hora de analizar problemas: ping, curl, tcpdump, pstack, gdb, traceroute, sqlplus
* Si se define en la instalación el parámetro env.SLEEP_AL_TERMINAR, el contenedor no se cerrara aunque se muera el proceso y las sondas darán OK
* En caso de querer depurar un contenedor que ya está corriendo, se puede crear un fichero vacío /export/manager/DEBUG. Mientras exista este fichero,
  el contenedor no se cerrará aunque se muera el proceso y las sondas darán OK
* Se puede cambiar el nivel de activación de trazas en caliente, simplemente modificando el fichero trazas/Configurar. El proceso relee y se reconfigura
  las trazas en la siguiente petición.

### Métricas

Las métricas que genera el proceso sharedconfman se exportan en el puerto 9100, en la URL /metrics.  Son las siguientes:

*  altamira_cnt_sharedconfman_total. Métrica de tipo counter, que se corresponde con los contadores tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de contador, y 'desc' para un nombre descriptivo del contador.  Por ejemplo
   ````
   altamira_cnt_sharedconfman_total{id="0000013",desc="ComandoEG"}
   ````
*  altamira_alrm_sharedconfman_total. Métrica de tipo counter, que se corresponde con las alarmas tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_alrm_sharedconfman_total{id="ALR0002018",desc="Perdida de conexión con la BBDD"}
   ````
*  altamira_cesable_sharedconfman. Métrica de tipo gauge, que se corresponde con las alarmas cesables de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_cesable_sharedconfman{id="ALR0002018",desc="Perdida de conexión con la BBDD"}
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
* Debe existir el namespace en que se vaya a instalar sharedconfman
* En el namespace en que se vaya a instalar tiene que existir un Secret de nombre oracle-secret con la configuración de acceso a oracle
* En el namespace en que se vaya a instalar tiene que existir un Secret de nombre zmq-secret con la configuración de cifrado de comunicaciones para 0MQ
* En la BD del SDP
  * La tabla ZMQC_CONEXIONES debe existir
  * La tabla ZMQA_ACTIVOS debe existir y tener la columna ZMQA_CDWORKER. Esta columna se ha añadido en un parche posterior a la creación de la tabla
    y es necesaria para esta versión
* Las imagenes de sharedconfman y metrics_aa_exporter deben estar subidas al repositorio del cluster. Dichas images se entregan como ficheros tgz.

## Instalacion

El chart se entrega comprimido en un fichero tgz. Si se desea, seria posible subir dicho fichero tgz a un servidor HTTP que haga de repositorio de charts e instalarlo desde alli. La otra posibilidad es instalar directamente desde el fichero, que es la que se detalla en este documento

* Como primer paso, generar un fichero con los values sobre el que podremos modificar los parametros que queramos
	````
	helm show values sharedconfman-13.3.1-0.tgz > values-sharedconfman-13.3.1-0.yaml
	````
* Modificar el fichero generado, particularizando los parametros que nos interesan.
Si no nos interesa modificar algún parámetro, lo podemos eliminar. Y si no queremos cambiar ningún parámetro de un objeto, podemos borrar el objeto completo. Los parámetros mas relevantes a revisar son los siguientes (el detalle de cada uno puede verse en el apartado de [ Configuración ](#configuración)  )
  * **containerSecurityContext**: En entornos productivos que requieran una mayor seguridad, quitar todas las capabilities y no reactivar ninguna
  * env.NIVEL_TRAZAS
  * env.CNF_OPENTELEMETRY_EXPORTER_TIPO
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * **env.CNF_ZMQ_CIFRADO**
  * **env.DATABASE_ENCRYPT**
  * **sharedconfman.image.repository**: Hay que definirlo obligatoriamente
  * **exporterImage.repository**: Hay que definirlo obligatoriamente
  * sharedconfman.resources

* Instalar el chart con las particularizaciones que se hayan definido en el fichero *values-sharedconfman.yaml*.  
  El \<namespace\> se recomienda que incluya el id del SDP con que se comunican los procesos y el nombre del servicio (por ejemplo aa-ocs-prepago1). Como \<release name\> se usa uno descriptivo de lo que se esta instalando, como *scm*
	````
	helm install -n <namespace> --create-namespace <release name> sharedconfman-13.3.1-0.tgz -f values-sharedconfman-13.3.1-0.yaml
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
| containerSecurityContext | object | `{}` | configuracion de seguridad del POD, para activar sólo las capabilities necesarias. En un entorno de producción    lo recomendable es dejar todas desactivadas, ya que sólo se usan para depuración y no son necesarias para el servicio |
| env.CNF_OPENTELEMETRY_EXPORTER_HOST | object | `{"value":"jaeger-agent.jaeger"}` | Host donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_PORT) Si es por UDP, se suele enviar a localhots o a un DaemonSet (indicando en CNF_OPENTELEMETRY_EXPORTER_HOST status.hostIP) Si es por HTTP se pone la direccion del jaeger agent, por ejemplo jaeger-agent.jaeger |
| env.CNF_OPENTELEMETRY_EXPORTER_PORT | object | `{"value":"6831"}` | Puerto donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_HOST) |
| env.CNF_OPENTELEMETRY_EXPORTER_TIPO | object | `{"value":"0"}` | Tipo de exporter de OpenTelemetry.  0-Ninguno, 1-Logs, 2-JaegerUDP, 3-JaegerHTTP |
| env.CNF_TRATAMIENTO_SIGTERM_CLOUD | object | `{"value":"2"}` | Tratamiento ante SIGTERM. 0-para, 2-indisponible y continua procesando lo que haya pendiente |
| env.CNF_ZMQ_CIFRADO | object | `{"value":"1"}` | Uso de cifrado en las conexiones 0MQ (las claves deben proporcionarse en el zmq-secret). Los procesos    de FED y BELS tienen que tener la misma configuració |
| env.CNF_ZMQ_UMBRAL_ENVIO_MISMO_NODO | object | `{"value":"0"}` | Numero de instancias de un servidor que debe haber en tu mismo nodo para activar el envio solo a instancias de     tu mismo nodo worker (0 para desactivar la funcionalidad) |
| env.DATABASE_ENCRYPT | object | `{"value":"1"}` | Variable para definir si la comunicacion con la BD se hace encriptada o no. Valor 0 indica no encriptada, valor 1 encriptada. |
| env.NIVEL_TRAZAS | object | `{"value":"0"}` | Nivel de trazas del proceso: 0-Todas. 1-Solo de error e informativas |
| exporterImage.repository | string | `"zape-k8s-dockreg:5000/metrics_aa_exporter"` | Repositorio de donde bajar el contenedor del exportador de metricas, para llevar los contadores del proceso prometheus |
| podAnnotations."prometheus.io/port" | string | `"9100"` | Puerto donde se sirven las metricas |
| podAnnotations."prometheus.io/scrape" | string | `"true"` | Anotacion para indicar a prometheus que debe recopilar metricas de estos pods |
| sharedconfman.funcionalidad | string | `"SHAREDCONFMAN"` | Funcionalidad para el gestor de memoria compartida (nombre) |
| sharedconfman.funcionalidadId | string | `"150"` | Funcionalidad para el gestor de memoria compartida (id) |
| sharedconfman.image.repository | string | `"zape-k8s-dockreg:5000/sharedconfman"` | Repositorio de donde bajar el contenedor del gencdr  |
| sharedconfman.resources | string | `nil` |  |
| sharedconfman.startupProbe.initialDelaySeconds | int | `300` |  |
| sharedconfman.startupProbe.periodSeconds | int | `30` |  |

