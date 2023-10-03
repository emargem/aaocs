# diametar

Version: 13.3.1-0
AppVersion: 13.3.1-0

Helm Chart para instalar en un cluster kubernetes el proceso de BELS que tarifica el tráfico de datos Gy (diametar).

## Descripción

Este chart instala el proceso diametar para un único SDP. En caso de tenerse varios SDP, habra que
instalarlo más de una vez, particularizando la información de conexión a la BD y el *namespace* en que se instala.

Si se desea usar memoria compartida, es posible instalar el SCM (gestor de memoria compartida) dentro del propio POD
del diametar, o usar un SCM que esté ya instalado previamente por fuera como un Daemonset.

Los procesos desplegados en cloud sólo reciben peticiones de otros procesos en cloud (en el caso de procesos externos, también pueden
recibir tráfico de los sistemas externos a través de un servicio kubernetes), lo que implica que estas instancias
de diametar sólo van a recibir tráfico que haya entrado por un diameterdatos desplegado en cloud.

Este documento presupone un despliegue en cloud de todos los procesos involucrados en el tratamiento del tráfico Gy. con la
excepción del servermsim:
* El tráfico se recibe por **diameterdatos**, en cloud
* En escenarios multisim, se consulta al **servermsim**, que reside en un FED tradicional
* La tarificación en sí la realiza el **diametar**, en cloud
* En caso de aplicar memoria compartida, los segmentos con los objetos compartidos los crea **sharedconfman**, en cloud
* Los eventos los envía diametar a **disteventos**, en cloud, que los propaga al SG
* Los CDRs los envía diametar a **gencdr**, en cloud
* Los CDRs agrupados en ficheros los manda al SG el **transcdr**, en cloud
* Si se habilita el envío a Kafka, los ficheros ya transmitidos al SG los reenvía a kafka el **envioKafka**, en cloud

### Funcionalidades desplegadas

El chart permite desplegar una funcionalidad de diametar (por defecto 86-DIAMETAR3GPP) y opcionalmente
una de sharedconfman (por defecto 150-SHAREDCONFMAN)
En caso de querer desplegar para otra funcionalidad sólo hay que particularizar en la instalacion los parametros
diametar.funcionalidad, diametar.funcionalidadId, sharedconfman.funcionalidad y sharedconfman.funcionalidadId

### Comunicaciones 0MQ

Los procesos desplegados en el cluster de kubernetes se comunican (tanto entre ellos como con otros procesos en la arquitectura
tradicional) usando la librería de comunicaciones 0MQ. Esta librería proporciona distintos tipos de socket, aunque en AltamirA
sólo se emplearán los sockets tipo ROUTER.

Cada proceso tendrá un socket ROUTER que hace de cliente, para enviar peticiones a otros proceso, y otro socket ROUTER
que hace de servidor, para recibir peticiones de otros procesos. Estos sockets son bidireccionales, por lo que las respuestas a
una petición se reciben por el mismo socket por el que se envio dicha petición.

El mecanismo que se ha implementado de comunicación por 0MQ se basa en dos tablas:

* La tabla ZMQC_CONEXIONES contiene la configuración de qué procesos se comunican por 0MQ y con quién. Dicha tabla debe estar configurada
  inicialmente para que DIAMETER3GPP, DIAMMSIM3GPP y DIAMSHARED3GPP se comuniquen por 0MQ con DIAMETAR3GPP. También debe estar configurado
  que DIAMETAR3GGP se comunique por 0MQ con GENCDR y DISTEVENTOS.
  * ZMQC_CDPROCESO_ORIGEN: Funcionalidad del proceso cliente, por ejemplo DIAMETER3GPP.
  * ZMQC_CDPROCESO_DESTINO: Funcionalidad del proceso servidor, por ejemplo DIAMETAR3GPP
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
  que los procesos en cloud pueden acceder al FED/BEL. Por ejemplo, si esta red es la 10.X.X.X, la variable RED_IP_ZMQ se definirá como "10.". Para los procesos que están en cloud no es necesario deefinir este parámetro RED_IP_ZMQ.

### Memoria compartida

DIAMETAR acceder a ciertas tablas de configuración en memoria compartida. Para ello, además de estar habilitado a nivel de BD, debe configurarse
en el propio cnf del DIAMETAR. A nivel cloud esto se consigue con el parámetro _memoriaCompartida_ del chart.

Es posible tener memoria compartida entre pods del mismo nodo worker, para lo cual debe haber un SCM desplegado por fuera de los POD de DIAMETAR
(es un DaemonSet, con lo que hay uno en cada nodo), y se debe tener activo _memoriaCompartida_ e inactivo _scmEnPod_. En este caso, el directorio
/dev/shm del nodo worker se monta como /dev/shm en todos los contenedores del POD.

![Comparticion de memoria en el pod](comparteWorker.png)

La otra alternativa es tener memoria compartida entre contenedores del mismo pod. En este caso se despliega un contenedor SCM junto con varias
instancias de DIAMETAR dentro del mismo pod. Se debe tener activo tanto _memoriaCompartida_ como _scmEnPod_, y debería haber varias instancias
de diametar (_diametar.instancias_) en el pod. En este caso, kubernetes proporciona un emptyDir soportado en memoria  que se monta en todos los
contenedores del POD como /dev/shm, que es el soporte de la memoria compartida.

![Comparticion de memoria en el worker](compartePod.png)

Si no se desea memoria compartida, es suficiente con desactivar el parámetro _memoriaCompartida_.

Un parametro importante cuando se usa memoria compartida es SHAREDMEM_AVAILABILITY_WAIT, que es el número máximo de segundos que DIAMETAR va a
esperar a que estén disponibles los segmentos de memoria compartida con los objetos leidos por SHAREDCONFMAN. Esta variable debe definirse en la
instalación (env.CNF_SHAREDMEM_AVAILABILITY_WAIT) con un valor suficiente como para que el SHAREDCONFMAN tenga tiempo de leer toda la configuración.

### Estructura del POD de diametar

El número de PODs desplegados lo define el parámetro _replicas_.
La estructura del POD depende de si se activa la memoria compartida con SCM en el pod (parámetros _memoriaCompartida_ y _scmEnPod_).

#### Con memoria compartida dentro del POD

![Estructura de un POD DIAMETAR+SCM](estructuraSCM.png)

Si están activos _memoriaCompartida_ y _scmEnPod_, cada POD se compone de los siguientes contenedores:
* N contenedores, de nombre 'proceso&lt;num&gt;' con procesos diametar, donde &lt;num&gt; es el número de instancia.
* 1 contenedor, de nombre 'proceso-scm', con el proceso sharedconfman.
* 1 exportador de métricas cuyo nombre es 'exporter'. Tiene un script que hace de acumulador, recopilando los contadores que generan diametar y sharedconfman, y generando el fichero de metricas. Tambien incluye un mini servidor http (implementado como un script), que escucha en el puerto 9100 y devuelve el fichero de métricas cuando se lo pide prometheus.

La comunicación entre el exporter y los otros procesos del pod se realiza mediante ficheros compartidos en un volumen de tipo
emptyDir, que proporciona kubernetes.

#### Con memoria compartida dentro del nodo worker

Si está activo _memoriaCompartida_ pero inactivo _scmEnPod_, no se despliega el contenedor proceso-scm dentro de cada POD. La memoria se comparte con
un SCM externo del mismo nodo, a través del /dev/shm del nodo worker

#### Sin memoria compartida

Si está inactivo _memoriaCompartida_, no se despliega el contenedor proceso-scm dentro de cada POD. Cada instancia del diametar lee todas las tablas
en memoria y no se usa la memoria compartida (y por tanto se desactiva la funcionalidad de tarifas personalizadas).

### Cifrado de comunicaciones

Es posible (y recomendable) cifrar las comunicaciones de los procesos en cloud con oracle, y con otros procesos de AltamirA.

Para el cifrado de las comunicaciones con otros procesos se usa el mecanismo Curve proporcionado por 0MQ, y se habilita en la
instalación. Es importante tener en cuenta que todos los procesos que intervengan en la comunicación, estén desplegados en cloud
o en un FED/BELS tradicional, tienen que tener la misma configuración de cifrado. Es decir, que las variables ZMQ_CIFRADO, ZMQ_CLAVE_PRIVADA
y ZMQ_CLAVE_PUBLICA de los procesos FED/BELS tienen que tomar los mismos valores que se asignen en el secret zmq-secret y en el
parametro CNF_ZMQ_CIFRADO del chart de Helm.

En el caso de las comunicaciones con oracle, la configuración recomendada es que el servidor tenga un puerto por TCP (por ejemplo el
tradicional 1521) y otro cifrado por TCPS. De esta forma, los procesos tradicionales pueden seguir comunicándose con la BD como siempre
mientras que los procesos en cloud usan un canal cifrado.
El mecanismo de cifrado opera con un wallet en el servidor en el que se registra la clave pública de los clientes. Y un wallet en los clientes
en el que se registra la clave pública del servidor. Este wallet de los clientes se debe proporcionar al cluster de kubernetes en el
secret oracle-secret.

### Procesado de tráfico Gy en cloud

En versiones anteriores sólo se podía instalar en cloud la capa de interface Gy (proceso diameterdatos). Por ello, las peticiones
pasaban del diameterdatos de cloud a los diametar del BELS tradicional. Con esta instalación, se incluyen en cloud procesos adicionales de la
cadena (diametar, gencdr, transcdr, disteventos), con lo que puede ser preferible que el tráfico Gy que se reciba en cloud se termine atendiendo
en un diametar en cloud, y se envíen sus CDRs y eventos también desde procesos cloud. De esta forma se tiene más aislado el tráfico y es
más sencillo identificar problemas.

Para ello se ha introducido un nuevo parámetro de cnf en el diameterdatos (ZMQ_SOLO_PROCS_CLOUD) que al activarse controla que de haber
procesos cloud y no cloud de una funcionalidad (por ejemplo DIAMETAR3GPP), sólo se envíen peticiones a los cloud.
En caso de sólo haber procesos no cloud (por ejemplo SERVERMSIM), la variable no afecta y se les siguen enviando peticiones como hasta ahora.

Este parámetro se entrega activo por defecto.

### Notificaciones USSD/SMS

Cuando se ejecuta en cloud, diametar no enviará notificaciones USSD o SMS, ni las asociadas a promociones (tabla TCE), ni las asociadas
a controles de gasto (tabla C9), ni las asociadas a la causa de liberación (tabla DMI).

### Limitación de recursos

Al instalar deben particularizarse los límites (resources del fichero values) de los procesos diametar y sharedconfman (
este último en caso de estar activo _memoriaCompartida_ y _scmEnPod_). Se deben configurar tanto los límites de cpu como los
de memoria. Por ejemplo:
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

### Envío dentro del mismo nodo worker

De cara a mejorar las prestaciones es posible configurar que los envíos por 0MQ a otros procesos cloud sólo se hagan dentro del mismo nodo
worker. Para ello hay que configurar el parámetro CNF_UMBRAL_ENVIO_MISMO_NODO con el número de instancias locales a partir del cual se considera
que hay suficientes interlocutores y se desactiva la comunicación con instancias de otros nodos worker.

Este parámetro se define a nivel de cliente y se usa el mismo valor para todos los destinos.
por ejemplo si se define un CNF_UMBRAL_ENVIO_MISMO_NODO=10 para DIAMETAR, y en el mismo nodo worker hay 10 GENCDR y 8 DISTEVENTOS,
los envíos DIAMETAR->GENCDR se harán sólo a GENCDR del mismo nodo worker, mientras que los envios DIAMETAR->DISTEVENTOS se harán todos los
DISTEVENTOS del cluster.

### Trazas de usuario

En cloud deja de tener sentido el envío de trazas de usuario al proceso GTRUSU. Estas trazas de usuario, en caso de estar activas, se generarán como
logs normales por la salida estándar, de tipo informativo para que se escriban independientemente del nivel de trazado configurado,
y con el prefijo TRUSU para que se puedan identicar en la pila ELK/EFK.

### Arbol de tarificación

En cloud el árbol de tarificación se lee de un ConfigMap, cuyo nombre para el escenario de tarificación de datos es 'arbol-datos'. Dicho ConfigMap tiene que estar creado en el mismo namespace
en el que se instala el proceso diametar. Dentro del config tiene que haber una entrada cuya clave sea el mismo nombre de árbol que se este usando (en el caso del diametar seria el valor del dato
de operador ARBOL_TARIFICACION) y cuyo contenido sea el árbol de tarificación completo.

El ConfigMap se monta desde el chart como un volumen en /export/manager/arbol y todos los árboles incluidos en este directorio se enlazan automáticamente desde /export/sdp/&lt;servicio&gt;/bcarga/&lt;funcionalidad&gt;,
con lo que pasan a estar disponibles de forma automática para el proceso.

Adicionalmente, diametar en cloud usa una nueva variable de cnf ID_ARBOLES_FLA como identificador del árbol (por defecto 'arbol-datos') para anotar en la tabla FLA cuando se hace una relectura del árbol.
Esta tabla es la que usa el monitor de relecturas para determinar si hay relecturas de árbol pendientes.

El contenedor se entrega con un árbol de tarificación mínimo, que simplemente es válido para que arranque el proceso. Es imprescindible particularizar el árbol con el configMap arbol-datos de forma
que se use el árbol correspondiente al servicio que se está instalando.

### Diccionario de AVPs

La imagen de diametar se entrega incluyendo un diccionario de AVPs unificado, compatible con los AVPs de Huawei, 3GPP y TME. En general este diccionario es válido
para los distintos tráficos Gy, independientemente del servicio que se esté instalando.

En caso de desear cambiar dicho diccionario, se puede proporcionar uno particularizado durante la instalación. 
Para ello debe crearse un ConfigMap con una entrada con clave dictionary.xml y cuyo valor es el contenido completo del diccionario.
El nombre de dicho ConfigMap se debe proporcionar durante la instalación en el parámetro *diametar.bcargaConfigmap*.

Este mecanismo vale para sustituir cualquier fichero del directorio bcarga en caso de ser necesario.

### Depuración en tiempo de ejecución

La imagen de diametar incluye varios mecanismos para la depuración en tiempo de ejecución:
* Se han instalado varias herramientas que pueden ser necesarias a la hora de analizar problemas: ping, curl, tcpdump, pstack, gdb, traceroute, sqlplus
* Si se define en la instalación el parámetro env.SLEEP_AL_TERMINAR, el contenedor no se cerrara aunque se muera el proceso y las sondas darán OK
* En caso de querer depurar un contenedor que ya está corriendo, se puede crear un fichero vacío /export/manager/DEBUG. Mientras exista este fichero,
  el contenedor no se cerrará aunque se muera el proceso y las sondas darán OK
* Se puede cambiar el nivel de activación de trazas en caliente, simplemente modificando el fichero trazas/Configurar. El proceso relee y se reconfigura
  las trazas en la siguiente petición.

### Autoescalado Horizontal (HPA)

Es posible definir un Horizontal POD Autoscaler (HPA) que controle el número de réplicas de diametar. Para ello hay que activar el parámetro
*autoscaling.enabled* del values.

Los parámetros *minReplicas* y *maxReplicas* controlan el número de PODs de diametar que se van a desplegar.

El umbral de escalado depende de si se usa el API v1 de autoscaling, o si se usa el API v2.
En caso de usar API v1, el parámetro *autoscaling.versionAPIv1* debe ser true, y el umbral se define en % de las requests en el parámetro
*autoscaling.targetCPUUtilizationValuev1*. En caso de usar API v2, el parámtro *autoscaling.versionAPIv1* debe ser false,
y el umbral se define en milicores en el parámetro *targetCPUUtilizationValue*.

La versión de API depende de la versión kubernetes que se esté usando.
````
kubectl api-versions | fgrep autoscaling
````

### Métricas

Las métricas que genera el pod diametar se exportan en el puerto 9100, en la URL /metrics. Son las siguientes:

*  altamira_cnt_diametar3gpp_total. Métrica de tipo counter, que se corresponde con los contadores tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de contador, y 'desc' para un nombre descriptivo del contador.  Por ejemplo
   ````
   altamira_cnt_diametar3gpp_total{id="0006000",desc="ContadorRequest"}
   ````
*  altamira_alrm_diametar3gpp_total. Métrica de tipo counter, que se corresponde con las alarmas tradicionales de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_alrm_diametar3gpp_total{id="ALR0001907",desc="Error al realizar una operación sobre BBDD"}
   ````
*  altamira_cesable_diametar3gp. Métrica de tipo gauge, que se corresponde con las alarmas cesables de AltamirA.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_cesable_diametar3gpp{id="ALR0002018",desc="Perdida de conexión con la BBDD"}
   ````

En caso de estar activos _memoriaCompartida_ y _scmEnPod_, las métricas generadas incluyen tambien las correspondientes al sharedconfman:

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
* Si se desea memoria compartida entre los POD del nodo worker
  * Debe estar instalado el sharedconfman como un DaemonSet independiente de este chart. En esté caso, en esta instalación se debe activar
    _memoraCompartida_ y desactivar _scmEnPod_
* Junto con este chart de diametar deben instalarse también los charts de diameterdatos, gencdr+transcdr, disteventos y sharedconfman (este último
  sólo si se tiene memoria compartida a nivel de nodo worker).
* Dado que todos los interlocutores de diametar se van a instalar también en cloud, diametar no va a comunicarse con ningún proceso de FED/BELS
  tradicionales, con lo que no es necesario configurar RED_IP_ZMQ, ZMQ_REGISTRO_ZMQA, ZMQ_CIFRADO, ZMQ_CLAVE_PUBLICA, ZMQ_CLAVE_PRIVADA para ningún
  proceso de FED/BELS. Si ya estaban configurados, se pueden dejar así, ya que no es un problema para el funcionamiento del sistema.
* Debe existir el namespace en que se vaya a instalar diametar
* En el namespace en que se vaya a instalar tiene que existir un ConfigMap de nombre arbol-datos que contenga una entrada con el árbol de tarificación
  del diametar. La clave de la entrada tiene que ser el mismo nombre de fichero de árbol usado en la actualidad (valor del dato de operador ARBOL_TARIFICACION)
  y su contenido será el árbol de tarificación completo.
* Si se necesita un diccionario de AVPs particular, distinto del incluido en la imagen, en el namespace en que se vaya a instalar debe existir un ConfigMap
  (por ejemplo con nombre diccionario-datos) que contenga una entrada con el nuevo diccionario. La clave de la entrada tiene que ser 'dictionary.xml' y su
  contenido será el nuevo diccionario. El nombre del configMap (e.g. diccionario-datos) deberá indicarse en la instalación en el parámetro *diametar.bcargaConfigmap*.
* En el namespace en que se vaya a instalar tiene que existir un Secret de nombre oracle-secret con la configuración de acceso a oracle
* En el namespace en que se vaya a instalar tiene que existir un Secret de nombre zmq-secret con la configuración de cifrado de comunicaciones para 0MQ
* En la BD del SDP
  * La tabla ZMQC_CONEXIONES debe existir y estar configurada con las nuevas conexiones 0MQ:
    * DIAMETAR3GPP -> GENCDR, con NUTIPOENVIO=0 y NUDIRCONEXION=0
  * La tabla ZMQA_ACTIVOS debe existir y tener la columna ZMQA_CDWORKER. Esta columna se ha añadido en un parche posterior a la creación de la tabla
    y es necesaria para esta versión
* Las imagenes de diametar, metrics_aa_exporter y sharedconfman deben estar subidas al repositorio del cluster. Dichas images se entregan como ficheros tgz.

## Instalacion

El chart se entrega comprimido en un fichero tgz. Si se desea, seria posible subir dicho fichero tgz a un servidor HTTP que haga de repositorio de charts e instalarlo desde alli. La otra posibilidad es instalar directamente desde el fichero, que es la que se detalla en este documento

* Como primer paso, generar un fichero con los values sobre el que podremos modificar los parametros que queramos
	````
	helm show values diametar-13.3.1-0.tgz > values-diametar-13.3.1-0.yaml
	````
* Modificar el fichero generado, particularizando los parametros que nos interesan.
Si no nos interesa modificar algún parámetro, lo podemos eliminar. Y si no queremos cambiar ningún parámetro de un objeto, podemos borrar el objeto completo. Los parámetros mas relevantes a revisar son los siguientes (el detalle de cada uno puede verse en el apartado de [ Configuración ](#configuración)  )

  * replicas
  * memoriaCompartida, scmEnPod
  * **containerSecurityContext**: En entornos productivos que requieran una mayor seguridad, quitar todas las capabilities y no reactivar ninguna
  * env.NIVEL_TRAZAS
  * env.CNF_OPENTELEMETRY_EXPORTER_TIPO
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * **env.CNF_ZMQ_CIFRADO**
  * **env.DATABASE_ENCRYPT**
  * **diametar.image.repository**: Hay que definirlo obligatoriamente
  * **exporterImage.repository**: Hay que definirlo obligatoriamente
  * **sharedconfman.image.repository**: Hay que definirlo obligatoriamente
  * diametar.resources
  * sharedconfman.resources
* Instalar el chart con las particularizaciones que se hayan definido en el fichero *values-diametar-13.3.1-0.yaml*.  
El \<namespace\> se recomienda que incluya el id del SDP con que se comunican los procesos y el nombre del servicio (por ejemplo aa-ocs-prepago1). Como \<release name\> se usa uno descriptivo de lo que se esta instalando, como *diametar*
	````
	helm install -n <namespace> <release name> diametar-13.3.1-0.tgz -f values-diametar-13.3.1-0.yaml
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
| autoscaling.enabled | bool | `false` | Activacion del HPA  |
| autoscaling.maxReplicas | int | `5` | Numero maximo de instancias  |
| autoscaling.minReplicas | int | `1` | Numero minimo de instancias  |
| autoscaling.targetCPUUtilizationValue | string | `"700m"` | Umbral de consumo de CPU de una instancia para que el HPA escale En API autoscaling/v1 el valor debe ser en porcentaje (70 = 70% de los cores reservados. p.ej con resources.requests.cpu=1 70% es el 70% de una CPU)  En API autoscaling/v2beta2 el valor debe ser en unidades de cores (700m son 700 milicores de 1 CPU = 70% de una CPU) |
| autoscaling.targetCPUUtilizationValuev1 | int | `70` |  |
| autoscaling.versionAPIv1 | bool | `true` |  |
| diametar.bcargaConfigmap | string | `nil` | Nombre del configmap con los archivos a desplegar en bcarga (distintos del arbol), por ejemplo el diccionario    Las claves son el nombre del archivo y los datos el contenido |
| diametar.funcionalidad | string | `"DIAMETAR3GPP"` |  |
| diametar.funcionalidadId | string | `"86"` |  |
| diametar.image.repository | string | `"zape-k8s-dockreg:5000/diametar"` | Repositorio de donde bajar el contenedor del diametar |
| diametar.instancias | int | `1` |  |
| diametar.resources | string | `nil` |  |
| diametar.startupProbe.failureThreshold | int | `20` |  |
| diametar.startupProbe.initialDelaySeconds | int | `300` |  |
| diametar.startupProbe.periodSeconds | int | `30` |  |
| env.CNF_OPENTELEMETRY_EXPORTER_HOST | object | `{"value":"jaeger-agent.jaeger"}` | Host donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_PORT) Si es por UDP, se suele enviar a localhots o a un DaemonSet (indicando en CNF_OPENTELEMETRY_EXPORTER_HOST status.hostIP) Si es por HTTP se pone la direccion del jaeger agent, por ejemplo jaeger-agent.jaeger |
| env.CNF_OPENTELEMETRY_EXPORTER_PORT | object | `{"value":"6831"}` | Puerto donde se envian los intervalos de OpenTelemetry (en conjuntcion con CNF_OPENTELEMETRY_EXPORTER_HOST) |
| env.CNF_OPENTELEMETRY_EXPORTER_TIPO | object | `{"value":"0"}` | Tipo de exporter de OpenTelemetry.  0-Ninguno, 1-Logs, 2-JaegerUDP, 3-JaegerHTTP |
| env.CNF_ZMQ_CIFRADO | object | `{"value":"1"}` | Uso de cifrado en las conexiones 0MQ (las claves deben proporcionarse en el zmq-secret). Los procesos    de FED y BELS tienen que tener la misma configuració |
| env.CNF_ZMQ_UMBRAL_ENVIO_MISMO_NODO | object | `{"value":"0"}` | Numero de instancias de un servidor que debe haber en tu mismo nodo para activar el envio solo a instancias de     tu mismo nodo worker (0 para desactivar la funcionalidad) |
| env.DATABASE_ENCRYPT | object | ... | Variable para definir si la comunicacion con la BD se hace encriptada o no. Valor 0 indica no encriptada, valor 1 encriptada. |
| env.NIVEL_TRAZAS | object | `{"value":"0"}` | Nivel de trazas del proceso: 0-Todas. 1-Solo de error e informativas |
| exporterImage.repository | string | `"zape-k8s-dockreg:5000/metrics_aa_exporter"` | Repositorio de donde bajar el contenedor del exportador de metricas, para llevar los contadores de diameterdatos a prometheus |
| memoriaCompartida | bool | `false` | Indica si el proceso usa memoria compartida |
| podAnnotations."prometheus.io/port" | string | `"9100"` | Puerto donde se sirven las metricas |
| podAnnotations."prometheus.io/scrape" | string | `"true"` | Anotacion para indicar a prometheus que debe recopilar metricas de estos pods |
| podSecurityContext | string | `nil` |  |
| replicas | int | `1` | Numero de pods de diametar que se despliegan |
| scmEnPod | bool | `false` | Indica que en el POD se incluya una instancia del sharedconfman.  |
| securityContext | object | `{}` | configuracion de seguridad del contenedor, para activar sólo las capabilities necesarias. En un entorno de producción    lo recomendable es dejar todas desactivadas, ya que sólo se usan para depuración y no son necesarias para el servicio |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| sharedconfman.funcionalidad | string | `"SHAREDCONFMAN"` | Funcionalidad para el gestor de memoria compartida (nombre) |
| sharedconfman.funcionalidadId | string | `"150"` | Funcionalidad para el gestor de memoria compartida (id) |
| sharedconfman.image.repository | string | `"zape-k8s-dockreg:5000/sharedconfman"` | Repositorio de donde bajar el contenedor del gestor de memoria compartida |
| sharedconfman.resources | string | `nil` |  |
| sharedconfman.startupProbe.failureThreshold | int | `20` |  |
| sharedconfman.startupProbe.initialDelaySeconds | int | `300` |  |
| sharedconfman.startupProbe.periodSeconds | int | `30` |  |

