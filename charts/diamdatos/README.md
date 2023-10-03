# diamdatos

Version: 13.3.1-4
AppVersion: 13.3.1-4

Helm Chart para instalar en un cluster kubernetes el proceso de FED del interface Gy (diameterdatos).

## Descripción

Este chart instala el proceso diameterdatos para un único SDP. En caso de tenerse varios SDP, habra que
instalarlo más de una vez, particularizando la información de conexión a la BD y el *namespace* en que se instala.

Hace un despliegue en dos capas, con una capa externa de interface que recibe las peticiones externas por el protocolo diameter
y las convierte al formato interno, y una capa interna que hace de distribuidor hacia los procesos tarificadores
y que escala de forma automatica con un HPA.

### Despliegue de múltiples funcionalidades

El proceso diameterdatos se despliega en el cluster de kubernetes como tres funcionalidades distintas:
DIAMETER3GPP, DIAMMSIM3GPP y DIAMSHARED3GPP. Los contenedores de funcionalidad DIAMETER3GPP envían peticiones
directamente a DIAMETAR3GPP, mientras que los contenedores de funcionalidad DIAMMSIM3GPP/DIAMSHARED3GPP primero
envían la petición al SERVERMSISM y luego, una vez determinado el MSISDN de cobro, la envían al DIAMETAR3GPP.

Cada una de estas funcionalidades se despliega con un servicio de entrada de tipo NodePort, con lo que habrá un
puerto definido para cada una de ellas.

![Diagrama de procesos](multiplesfuncionalidades.png)

El proceso diameterdatos se conecta con la Base de datos del SDP y envía peticiones a los procesos DIAMETAR3GPP y SERVERMSIM
de dicho SDP, por lo que necesita conectividad de red desde los pods del cluster kubernetes con FED, BELS y BEBD.

### Despliegue en dos capas

Cada funcionalidad del proceso diameterdatos se despliega en dos capas, con una capa de interface que implementa el protocolo
diameter y una capa de procesado, que trabaja ya con peticiones en el formato interno SDP y que es la que se comunica con el
SERVERMSIM o con el DIAMETAR3GPP.

![Diagrama de dos capas](doscapas.png)

La comunicación entre las instancias de capa 1 (interface) y de capa 2 (procesado) se realiza mediante conexiones [0MQ](#comunicaciones-0mq),, al
igual que la comunicación entre las instancias de capa 2 (procesado) y los procesos de los FED/BELS tradicionales (SERVERMSIM y
DIAMETAR3GPP)

El número de instancias en capa de interface debería ser relativamente estable, ya que si se levantan instancias nuevas, éstas
no se usarán a menos que se fuerce al DRA a abrir conexiones nuevas.

El número de instancias en capa de procesado, en cambio, puede variar sin problemas. Por ello; en el despliegue se incluye un HPA
(Horizontal Por Autoscaler), que escala la capa de procesado en función de cuanta CPU consuma.

### Comunicaciones 0MQ

Los procesos desplegados en el cluster de kubernetes se comunican (tanto entre ellos como con otros procesos en la arquitectura
tradicional) usando la librería de comunicaciones 0MQ. Esta librería proporciona distintos tipos de socket, aunque en AltamirA
sólo se emplearán los sockets tipo ROUTER.

Cada proceso tendrá un socket ROUTER que hace de cliente, para enviar peticiones a otros proceso, y otro socket ROUTER
que hace de servidor, para recibir peticiones de otros procesos. Estos sockets son bidireccionales, por lo que las respuestas a
una petición se reciben por el mismo socket por el que se envio dicha petición.

El mecanismo que se ha implementado de comunicación por 0MQ se basa en dos tablas:

* La tabla ZMQC_CONEXIONES contiene la configuración de qué procesos se comunican por 0MQ y con quién. Dicha tabla debe estar configurada
  inicialmente para que DIAMETER3GPP, DIAMMSIM3GPP y DIAMSHARED3GPP se comuniquen por 0MQ con SERVERMSIM y DIAMETAR3GPP. Dado que el envío
  por 0MQ sólo se hace en procesos cloud, es posible tener unos procesos diameterdatos que se comuniquen con diametar por 0MQ
  (los que están en cloud) mientras que otros procesos se sigan comunicando por el protocolo SDP_SDP tradicional (los que estén en un FED normal).
  * ZMQC_CDPROCESO_ORIGEN: Funcionalidad del proceso cliente, por ejemplo DIAMETER3GPP.
  * ZMQC_CDPROCESO_DESTINO: Funcionalidad del proceso servidor, por ejemplo DIAMETAR3GPP
  * ZMQC_NUTIPOENVIO: 0 si el envío es por round-robin. 1 si el envío es serializado a una instancia particular, 2 si el envio es local
    a la instancia equivalente
* La tabla ZMQA_ACTIVOS se actualiza automáticamente con la IP y puerto de los sockets ROUTER de tipo servidor, de aquellos procesos
  que pueden ser destino de una comunicación 0MQ, según la configuración de ZMQC. Esta tabla se monitoriza periódicamente por todos los
  procesos clientes, de forma que puedan detectar si algún proceso nuevo se ha levantado o algún proceso se ha parado.

  Un proceso sólo se registra en esta tabla (los que no se registran no van a recibir peticiones 0MQ) si tiene activo el parámetro de cnf
  ZMQ_REGISTRO_ZMQA.
  Cuando el proceso a registrar en la ZMQA está en una máquina con varios interfaces de red (en un FED o BEL), la IP que se anota en la tabla
  es la primera que cumpla el patrón definido en el parámetro de cnf RED_IP_ZMQ. En este parámetro deberá definirse la red externa por la
  que los procesos en cloud pueden acceder al FED/BEL. Por ejemplo, si esta red es la 10.X.X.X, la variable RED_IP_ZMQ se definirá como "10.".

### Estructura del contenedor de diameterdatos

Independientemente de que funcione como DIAMETER3GPP, DIAMMSIM3GPP o DIAMSHARED3GPP, todos los contenedores del
diameterdatos ejecutan la misma imagen y, por tanto, tienen la misma estructura:

![Estructura de un POD](estructura.png)

El POD de diameterdatos se compone de dos contenedores:
* El primero de ellos, de nombre 'proceso' es el diameterdatos en si. Escucha DIAMETER en el puerto 3890
* El segundo es el exportador de métricas y su nombre es 'exporter'. Tiene un script que hace de acumulador, recopilando los
  contadores que genera el diameterdatos y generando el fichero de metricas. Tambien incluye un mini servidor http (implementado
  como un script), que escucha en el puerto 9100 y devuelve el fichero de métricas cuando se lo pide prometheus.

La comunicación entre estos dos contenedores dentro del pod se realiza mediante ficheros compartidos en un volumen de tipo
emptyDir, que proporciona kubernetes.

### Cifrado de comunicaciones

Es posible (y recomendable) cifrar las comunicaciones de los procesos en cloud con oracle, y con otros procesos de AltamirA.

Para el cifrado de las comunicaciones con otros procesos se usa el mecanismo Curve proporcionado por 0MQ, y se habilita en la
instalación. Es importante tener en cuenta que tanto los procesos diameterdatos en cloud como los procesos tradicionales con los que
éstos se comunican, tienen que tener la misma configuración de cifrado. Es decir, que las variables ZMQ_CIFRADO, ZMQ_CLAVE_PRIVADA
y ZMQ_CLAVE_PUBLICA de DIAMETAR3GPP/SERVERMSIM tienen que tomar los mismos valores que se asignen en el secret zmq-secret y en el
parametro CNF_ZMQ_CIFRADO del chart de Helm.

En el caso de las comunicaciones con oracle, la configuración recomendada es que el servidor tenga un puerto por TCP (por ejemplo el
tradicional 1521) y otro cifrado por TCPS. De esta forma, los procesos tradicionales pueden seguir comunicándose con la BD como siempre
mientras que los procesos en cloud usan un canal cifrado.
El mecanismo de cifrado opera con un wallet en el servidor en el que se registra la clave pública de los clientes. Y un wallet en los clientes
en el que se registra la clave pública del servidor. Este wallet de los clientes se debe proporcionar al cluster de kubernetes en el
secret oracle-secret.

### Diccionario de AVPs

La imagen de diameterdatos se entrega incluyendo un diccionario de AVPs unificado, compatible con los AVPs de Huawei, 3GPP y TME. En general este diccionario es válido
para los distintos tráficos Gy, independientemente del servicio que se esté instalando.

En caso de desear cambiar dicho diccionario, se puede proporcionar uno particularizado durante la instalación.
Para ello debe crearse un ConfigMap con una entrada con clave dictionary.xml y cuyo valor es el contenido completo del diccionario.
El nombre de dicho ConfigMap se debe proporcionar durante la instalación en el parámetro *bcargaConfigmap*.

Este mecanismo vale para sustituir cualquier fichero del directorio bcarga en caso de ser necesario.

### Depuración en tiempo de ejecución

La imagen de diamdatos incluye varios mecanismos para la depuración en tiempo de ejecución:
* Se han instalado varias herramientas que pueden ser necesarias a la hora de analizar problemas: ping, curl, tcpdump, pstack, gdb, traceroute, sqlplus
* Si se define en la instalación el parámetro env.SLEEP_AL_TERMINAR, el contenedor no se cerrara aunque se muera el proceso y las sondas darán OK
* En caso de querer depurar un contenedor que ya está corriendo, se puede crear un fichero vacío /export/manager/DEBUG. Mientras exista este fichero,
  el contenedor no se cerrará aunque se muera el proceso y las sondas darán OK
* Se puede cambiar el nivel de activación de trazas en caliente, simplemente modificando el fichero trazas/Configurar. El proceso relee y se reconfigura
  las trazas en la siguiente petición.

### Autoescalado Horizontal (HPA)

Es posible definir un Horizontal POD Autoscaler (HPA) que controle el número de réplicas de diameterdatos. Para ello hay que activar el parámetro
*autoscaling.enabled* del values.

Los parámetros *minReplicas* y *maxReplicas* controlan el número de PODs de diameterdatos que se van a desplegar.

El umbral de escalado depende de si se usa el API v1 de autoscaling, o si se usa el API v2.
En caso de usar API v1, el parámetro *autoscaling.versionAPIv1* debe ser true, y el umbral se define en % de las requests en el parámetro
*autoscaling.targetCPUUtilizationValuev1*. En caso de usar API v2, el parámtro *autoscaling.versionAPIv1* debe ser false,
y el umbral se define en milicores en el parámetro *targetCPUUtilizationValue*.

La versión de API depende de la versión kubernetes que se esté usando.
````
kubectl api-versions | fgrep autoscaling
````

### Métricas

Las métricas que genera el pod diameterdatos se exportan en el puerto 9100, en la URL /metrics. Son las siguientes:

*  altamira_cnt_diameter3gpp_total. Métrica de tipo counter, que se corresponde con los contadores tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de contador, y 'desc' para un nombre descriptivo del contador.  Por ejemplo
   ````
   altamira_cnt_diameter3gpp_total{id="0001014",desc="ConexionEstablecidaPorCliente"}
   ````
*  altamira_alrm_diameter3gpp_total. Métrica de tipo counter, que se corresponde con las alarmas tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_alrm_diameter3gpp_total{id="ALR0012024",desc="Perdida de conexion con el nodo GGSN %s"}
   ````
*  altamira_cesable_diameter3gp. Métrica de tipo gauge, que se corresponde con las alarmas cesables de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_cesable_diamet3r3gpp{id="ALR0012024",desc="Perdida de conexion con el nodo GGSN %s"}
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
* En los BELs del SDP
  * Cada BEL deben tener una IP externa, a la que se pueda acceder desde el cluster de kubernetes. El puerto de conexion se
  asigna aleatoriamente al arrancar.
  * En el cnf del DIAMETAR3GPP en los BELs debe aparecer la nueva variable RED_IP_ZMQ, con la IP externa del BEL
  * En el cnf del DIAMETAR3GPP en los BELS debe aparecer la nueva variable ZMQ_REGISTRO_ZMQA con el valor 1
  * Si se desean comunicaciones 0MQ cifradas, el cnf del DIAMETAR3GPP en los BELS tiene que tener la misma configuración de cifrado que el chart
    * ZMQ_CIFRADO en DIAMETAR3GPP.cnf debe ser igual que CNF_ZMQ_CIFRADO en las variables de entorno al instalar el chart
    * ZMQ_CLAVE_PUBLICA en DIAMETAR3GPP.cnf debe ser igual que el parametro CLAVE_PUBLICA del secret zmq-secret
    * ZMQ_CLAVE_PRIVADA en DIAMETAR3GPP.cnf debe ser igual que el parametro CLAVE_PRIVADA del secret zmq-secret
* En los FEDs del SDP
  * Cada FED del SDP deben tener una IP externa, a la que se pueda acceder desde el cluster de kubernetes. El puerto de conexion se
  asigna aleatoriamente al arrancar.
  * En el cnf del SERVERMSIM en los FEDs debe aparecer la nueva variable RED_IP_ZMQ, con la IP externa del FED
  * En el cnf del SERVERMSIM en los FEDs debe aparecer la nueva variable ZMQ_REGISTRO_ZMQA con el valor 1
  * Si se desean comunicaciones 0MQ cifradas, el cnf del SERVERMSIM en los FEDS tiene que tener la misma configuración de cifrado que el chart
    * ZMQ_CIFRADO en SERVERMSIM.cnf debe ser igual que CNF_ZMQ_CIFRADO en las variables de entorno al instalar el chart
    * ZMQ_CLAVE_PUBLICA en SERVERMSIM.cnf debe ser igual que el parametro CLAVE_PUBLICA del secret zmq-secret
    * ZMQ_CLAVE_PRIVADA en SERVERMSIM.cnf debe ser igual que el parametro CLAVE_PRIVADA del secret zmq-secret
* En la BD del SDP
  * La tabla ZMQC_CONEXIONES debe existir y estar configurada con las nuevas conexiones 0MQ:
  * La tabla ZMA_ACTIVOS debe existir y en ella deben aparecer todos los procesos DIAMETAR3GPP y SERVERMSISM de ese SDP (esto indica que se ha instalado la nueva version de los procesos compatible con clientes en cloud, y que los procesos se han reiniciado despues de la configuracion de las variables en el cnf)
* Las imagenes de diameterdatos y metrics_aa_exporter deben estar subidas al repositorio del cluster. Dichas images se entregan como ficheros tgz.

## Instalacion

El chart se entrega comprimido en un fichero tgz. Si se desea, seria posible subir dicho fichero tgz a un servidor HTTP que haga de repositorio de charts e instalarlo desde alli. La otra posibilidad es instalar directamente desde el fichero, que es la que se detalla en este documento

* Como primer paso, generar un fichero con los values sobre el que podremos modificar los parametros que queramos
	````
	helm show values diamdatos-13.3.1-4.tgz > values-diamdatos-13.3.1-4.yaml
	````
* Modificar el fichero generado, particularizando los parametros que nos interesan.
Si no nos interesa modificar algún parámetro, lo podemos eliminar. Y si no queremos cambiar ningún parámetro de un objeto, podemos borrar el objeto completo. Los parámetros mas relevantes a revisar son los siguientes
  * replicaCount1
  * replicaCount2
  * **databaseUser**: Hay que definirlo obligatoriamente
  * **databaseName**: Hay que definirlo obligatoriamente
  * **tnsname.ora**: Hay que definirlo obligatoriamente
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
* Instalar el chart con las particularizaciones que se hayan definido en el fichero *values-diamdatos.yaml*.  
El \<namespace\> se recomienda que incluya el id del SDP con que se comunican los procesos (por ejemplo aa-ocs-sdp1). Como \<release name\> se usa uno descriptivo de lo que se esta instalando, como *gyifz*
	````
	helm install -n <namespace> --create-namespace <release name> diamdatos-13.3.1-4.tgz -f values-diamdatos-13.3.1-4.yaml
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
| autoscaling.enabled | bool | `true` | Activacion del HPA en la capa 2 del diameterdatos |
| autoscaling.maxReplicas | int | `5` | Numero maximo de instancias en la capa de procesado |
| autoscaling.minReplicas | int | `1` | Numero minimo de instancias en la capa de procesado |
| autoscaling.targetCPUUtilizationValue | string | `"700m"` | Umbral de consumo de CPU de una instancia para que el HPA escale En API autoscaling/v1 el valor debe ser en porcentaje (70 = 70% de los cores reservados. p.ej con resources.requests.cpu=1 70% es el 70% de una CPU)  En API autoscaling/v2beta2 el valor debe ser en unidades de cores (700m son 700 milicores de 1 CPU = 70% de una CPU) |
| autoscaling.targetCPUUtilizationValuev1 | int | `70` |  |
| autoscaling.versionAPIv1 | bool | `true` |  |
| bcargaConfigmap | string | `nil` | Nombre del configmap con los archivos a desplegar en bcarga (distintos del arbol), por ejemplo el diccionario    Las claves son el nombre del archivo y los datos el contenido |
| containerSecurityContext | object | `{}` | configuracion de seguridad del POD, para activar sólo las capabilities necesarias. En un entorno de producción    lo recomendable es dejar todas desactivadas, ya que sólo se usan para depuración y no son necesarias para el servicio |
| diam3gpp.enabled | bool | `true` | Activacion de la funcionalidad  |
| diam3gpp.funcionalidad | string | `"DIAMETER3GPP"` | Nombre de la funcionalidad que se esta desplegando |
| diam3gpp.funcionalidad_id | int | `85` | Identificador (tabla AD) de la funcionalidad que se esta desplegando |
| diam3gpp.instanciaCount1 | int | `1` | Numero de instancias dentro del POD de capa 1 |
| diam3gpp.instanciaCount2 | int | `1` | Numero de instancias dentro del POD de capa 2 |
| diam3gpp.replicaCount1 | int | `1` | Numero de replicas del diameterDatos que se levantan en capa 1 (interface) |
| diam3gpp.replicaCount2 | int | `1` | Numero de instancias del diameterDatos que se levantan en capa 2 (procesado/distribucion) |
| diam3gpp.service.nodePort | int | `31007` | Puerto externo donde recibir conexiones del interface Gy |
| diam3gpp.service.port | int | `31007` | Puerto interno donde recibir conexiones del interface Gy |
| diam3gpp.service.type | string | `"NodePort"` | Tipo de servicio de entrada del interface Gy |
| diamshared3gpp.enabled | bool | `true` | Activacion de la funcionalidad  |
| diamshared3gpp.funcionalidad | string | `"DIAMSHARED3GPP"` | Nombre de la funcionalidad que se esta desplegando |
| diamshared3gpp.funcionalidad_id | int | `83` | Identificador (tabla AD) de la funcionalidad que se esta desplegando |
| diamshared3gpp.instanciaCount1 | int | `1` | Numero de instancias dentro del POD de capa 1 |
| diamshared3gpp.instanciaCount2 | int | `1` | Numero de instancias dentro del POD de capa 2 |
| diamshared3gpp.replicaCount1 | int | `1` | Numero de instancias del diameterDatos que se levantan en capa 1 (interface) |
| diamshared3gpp.replicaCount2 | int | `1` | Numero de instancias del diameterDatos que se levantan en capa 2 (procesado/distribucion) |
| diamshared3gpp.service.nodePort | int | `31207` | Puerto externo donde recibir conexiones del interface Gy |
| diamshared3gpp.service.port | int | `31207` | Puerto interno donde recibir conexiones del interface Gy |
| diamshared3gpp.service.type | string | `"NodePort"` | Tipo de servicio de entrada del interface Gy |
| diamsim3gpp.enabled | bool | `true` | Activacion de la funcionalidad  |
| diamsim3gpp.funcionalidad | string | `"DIAMMSIM3GPP"` | Nombre de la funcionalidad que se esta desplegando |
| diamsim3gpp.funcionalidad_id | int | `89` | Identificador (tabla AD) de la funcionalidad que se esta desplegando |
| diamsim3gpp.instanciaCount1 | int | `1` | Numero de instancias dentro del POD de capa 1 |
| diamsim3gpp.instanciaCount2 | int | `1` | Numero de instancias dentro del POD de capa 2 |
| diamsim3gpp.replicaCount1 | int | `1` | Numero de instancias del diameterDatos que se levantan en capa 1 (interface) |
| diamsim3gpp.replicaCount2 | int | `1` | Numero de instancias del diameterDatos que se levantan en capa 2 (procesado/distribucion) |
| diamsim3gpp.service.nodePort | int | `31107` | Puerto externo donde recibir conexiones del interface Gy |
| diamsim3gpp.service.port | int | `31107` | Puerto interno donde recibir conexiones del interface Gy |
| diamsim3gpp.service.type | string | `"NodePort"` | Tipo de servicio de entrada del interface Gy |
| env.CELULA | object | `{"value":"1"}` | Celula en la que se despliega el chart. Por defecto celula 1. |
| env.CNF_OPENTELEMETRY_EXPORTER_HOST | object | `{"value":"jaeger-agent.jaeger"}` | Host donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_PORT) Si es por UDP, se suele enviar a localhots o a un DaemonSet (indicando en CNF_OPENTELEMETRY_EXPORTER_HOST status.hostIP) Si es por HTTP se pone la direccion del jaeger agent, por ejemplo jaeger-agent.jaeger |
| env.CNF_OPENTELEMETRY_EXPORTER_PORT | object | `{"value":"6831"}` | Puerto donde se envian los intervalos de OpenTelemetry (en conjuntcion con CNF_OPENTELEMETRY_EXPORTER_HOST) |
| env.CNF_OPENTELEMETRY_EXPORTER_TIPO | object | `{"value":"0"}` | Tipo de exporter de OpenTelemetry.  0-Ninguno, 1-Logs, 2-JaegerUDP, 3-JaegerHTTP |
| env.CNF_ZMQ_CIFRADO | object | `{"value":"1"}` | Uso de cifrado en las conexiones 0MQ (las claves deben proporcionarse en el zmq-secret). Los procesos    de FED y BELS tienen que tener la misma configuració |
| env.CNF_ZMQ_SOLO_MISMA_CELULA | object | `{"value":"0"}` | Variable para forzar que los procesos se comuniquen solo con funcionalides de la misma celula. Por defecto 0 para evitarlo. |
| env.CNF_ZMQ_UMBRAL_ENVIO_MISMO_NODO | object | `{"value":"0"}` | Numero de instancias de un servidor que debe haber en tu mismo nodo para activar el envio solo a instancias de     tu mismo nodo worker (0 para desactivar la funcionalidad) |
| env.DATABASE_ENCRYPT | object | ... | Variable para definir si la comunicacion con la BD se hace encriptada o no. Valor 0 indica no encriptada, valor 1 encriptada. |
| env.NIVEL_TRAZAS | object | `{"value":"0"}` | Nivel de trazas del proceso: 0-Todas. 1-Solo de error e informativas |
| env.SERVICIO | object | `{"value":"PREPAGO"}` | Servicio AA para el que se despliega este chart (Etiqueta e Identificador) |
| env.SERVICIO_ID.value | string | `"1"` |  |
| env.SLEEP_AL_TERMINAR | object | `{"value":"0"}` | Variable para definir el número de segundos que se mantienevivo  el pod una vez que se ha muerto el proceso. Util para depuracion |
| exporterImage.repository | string | `"zape-k8s-dockreg:5000/metrics_aa_exporter"` | Repositorio de donde bajar el contenedor del exportador de metricas, para llevar los contadores de diameterdatos a prometheus |
| image.repository | string | `"zape-k8s-dockreg:5000/diameterdatos"` | Repositorio de donde bajar el contenedor del diameterdatos (version en Chart.yaml/appVersion) |
| podAnnotations."prometheus.io/port" | string | `"9100"` | Puerto donde se sirven las metricas |
| podAnnotations."prometheus.io/scrape" | string | `"true"` | Anotacion para indicar a prometheus que debe recopilar metricas de estos pods |
| podSecurityContext | string | `nil` |  |
| resources | object | `{"limits":{"cpu":1},"requests":{"cpu":1}}` | Recursos de CPU. Limite y requests. Son valores aplicados unicamente a los contenedores proceso de las funcionalidades diameterDatos-proc. Es necesario su definicion para el uso de HPA con autoscaling/v1 |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
