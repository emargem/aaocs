# gencdr

Version: 13.3.1-0
AppVersion: 13.3.1-0

Helm Chart para instalar en un cluster kubernetes los procesos de FED para el envío de CDRs (gencdr y transcdr).

## Descripción

Este chart instala los procesos gencdr+transcdr para un único SDP. En caso de tenerse varios SDP, habra que
instalarlos más de una vez, particularizando la información de conexión a la BD y el *namespace* en que se instala.

Gencdr y transcdr se incluyen en un mismo POD, ya que la comunicación entre ambos es a través de localhost,
enviándose el PATH a los ficheros, en vez del contenido de los mismos.

Adicionalmente se ha incluido un POD enviokafka que permite reenviar a Kafka los ficheros de CDRs despues de su
envío al SG

### Funcionalidades desplegadas

El chart permite desplegar una funcionalidad de gencdr (por defecto 29-GENCDR) y una de transcdr (por defecto 30-TRANSCDR).
En caso de querer desplegar para otra funcionalidad sólo hay que particularizar en la instalacion los parametros
gencdr.funcionalidad, gencdr.funcionalidadId, transcdr.funcionalidad, transcdr.funcionalidadId.
Si se desean varias funcionalidades gencdr (cada instancia de gencdr lleva su transcdr en el mismo pod),
hay que instalar varias veces.

### Comunicaciones 0MQ

Los procesos desplegados en el cluster de kubernetes se comunican (tanto entre ellos como con otros procesos en la arquitectura
tradicional) usando la librería de comunicaciones 0MQ. Esta librería proporciona distintos tipos de socket, aunque en AltamirA
sólo se emplearán los sockets tipo ROUTER.

Cada proceso tendrá un socket ROUTER que hace de cliente, para enviar peticiones a otros proceso, y otro socket ROUTER
que hace de servidor, para recibir peticiones de otros procesos. Estos sockets son bidireccionales, por lo que las respuestas a
una petición se reciben por el mismo socket por el que se envio dicha petición.

El mecanismo que se ha implementado de comunicación por 0MQ se basa en dos tablas:

* La tabla ZMQC_CONEXIONES contiene la configuración de qué procesos se comunican por 0MQ y con quién. Dicha tabla debe estar configurada
  inicialmente para que haya comunicación 0MQ de DIAMETAR3GPP con GENCDR, y de GENCDR con TRANSCDR
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

### Estructura del pod gencdr+transcdr

Gencdr y transcdr se entregan integrados en un mismo POD, de forma que puedan comunicarse entre si via localhost.

![Estructura de un POD](estructura.png)

El número de contenedores incluido en el POD depende del tipo de despliegue que se seleccione en la instalación (parámetro
*despliegueDaemonSet*), así como de los parámetros *replicasDeployment* e *instancias*.

Los ficheros de contadores se pasan de los contenedores gencdr/transcdr al exporter usando un emptyDir montado en todos los contenedores.
Los ficheros de CDRs se pasan de los gencdr a los transcdr a través de un sistema de ficheros montado en /export/sdp/&lt;servicio&gt;/datos/comun. Este sistema de fichero tiene que ser un PersistentVolume, a fin de que no se pierdan los CDRs en caso de caída de un POD. Todos los contenedores gencdr y transcdr de todos los PODs de un nodo worker montan el mismo PersistentVolumen y dejan sus ficheros de CDRs en el mismo sitio.

#### Estructura del pod gencdr+transcdr en un despliegue de tipo deployment

En un despliegue tipo Deployment (parámetro *despliegueDaemonset* = false), se despliegan N instancias del POD (N = parámetro *replicasDeployment*)
repartidas entre los distintos nodos worker.
Cada réplica del POD se compondrá de:
* N contenedores, de nombre 'proceso-gen&lt;num&gt;' con procesos gencdr. Recibirán peticiones de los tarificadores por 0MQ (N es el número de *instancias*)
* N contenedores, de nombre 'proceso-trans&lt;num&gt;' con el proceso transcdr. Recibe peticiones del gencdr asociado ( cada gencdr
  se comunica con el transcdr de su mismo POD, celula e instancia)
* Un exportador de métricas cuyo nombre es 'exporter'. Tiene un script que hace de acumulador, recopilando los
  contadores que generan gencdr y transcdr, y generando el fichero de metricas. Tambien incluye un mini servidor http (implementado
  como un script), que escucha en el puerto 9100 y devuelve el fichero de métricas cuando se lo pide prometheus.

La comunicación entre estos los proceso-gen/proceso-trans y el exporter dentro del pod se realiza mediante ficheros compartidos en un volumen de tipo
emptyDir, que proporciona kubernetes.

En este tipo de despliegue se podría incluir un HPA que realice el autoescalado horizontal, variando el número de PODS en función de la carga;
aunque por defecto no se incluye este HPA en el chart.

Los ficheros de CDRs incluyen en su nombre el hostname del POD que genera el CDR. Dado que en cloud estos nombres se asignan aleatoriamente, este tipo
de despliegue no es válido si se necesita que haya un conjunto limitado de máquinas desde las que se generen los CDRs (por ejemplo, si en el sistema
destino se tiene un filtro para sólo admitir ficheros con ciertos hostnames).

#### Estructura del pod gencdr+transcdr en un despliegue de tipo daemonset

En un despliegue tipo Daemonset (parámetro *despliegueDaemonset* = true), se despliega una instancia del POD en cada uno de los nodos worker.
En este caso, para permitir cierta escalabilidad (aunque no podra ser automática), el número de gencdrs incluidos en el POD vendrá
determinado por el parámetro *instancias*.  Cada réplica del POD se compondrá :
* N contenedores, de nombre 'proceso-gen&lt;num&gt;' con procesos gencdr. Recibirán peticiones de los tarificadores por 0MQ. (N es el número de *instancias*)
* N contenedores, de nombre 'proceso-trans&lt;num&gt;' con el proceso transcdr. Recibe peticiones del gencdr asociado ( cada gencdr
  se comunica con el transcdr de su mismo POD, celula e instancia)
* Un exportador de métricas cuyo nombre es 'exporter'. Tiene un script que hace de acumulador, recopilando los
  contadores que generan gencdr y transcdr, y generando el fichero de metricas. Tambien incluye un mini servidor http (implementado
  como un script), que escucha en el puerto 9100 y devuelve el fichero de métricas cuando se lo pide prometheus.

La comunicación entre estos los proceso-gen&lt;num&gt;/proceso-trans y el exporter dentro del pod se realiza mediante ficheros compartidos
en un volumen de tipo emptyDir, que proporciona kubernetes.

El despliegue daemonset es incompatible con un HPA.

En este tipo de despliegue, el nombre de hostname que se pone en los ficheros de CDRs es el del nodo worker, lo que permite tener un conjunto limitado
de maquinas desde las que se generen los CDRs, en caso de requerirse.

### Estructura del pod enviokafka

El proceso de envío a kafka es un proceso experimental que permite reenviar a Kafka los ficheros ya enviados al SG. Este POD sólo se despliega
si está activo *kafka.envio*, y se compone de:
* 1 contenedor, de nombre 'proceso-enviokafka-normal', que se encarga de enviar a Kafka los ficheros de CDRs del directorio CDR_SG/TRANSMITIDOS/NORMAL
* 1 contenedor, de nombre 'proceso-enviokafka-hotbilling', que se encarga de enviar a Kafka los ficheros de CDRs del directorio CDR_SG/TRANSMITIDOS/HOTBILLING

Los ficheros se envían completos, tal y como los recibiría el SG, incluyendo el nombre del fichero (que a su vez incluye el hostname de la maquina en la que
se generó) como clave

Este POD es experimental y no genera métricas (al no ser un proceso estándar de la plataforma SDP no tiene el mecanismo habitual de contadores).

Estos PODs de envío a Kafka se despliegan en modo Daemonset, con lo que hay uno por cada nodo worker, y acceden al mismo PersistenVolume que los
PODS de gencdr+transcdr

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

### Almacenamiento persistente

Gencdr y Transcdr necesitan un almacenamiento persistente donde ir guardando los ficheros con los CDRs. Estos ficheros de CDR llevan el
nombre de la maquina en la que se crean (si el despliegue es de tipo deployment es el hostname del pod, si el despliegue es de tipo
daemonset es el nombre del nodo worker). Si un gencdr desaparece y deja algun fichero pendiente, este fichero se lo autoasignara otro
gencdr renombrandolo como si lo hubiese generado el.

Este almacenamiento persistente se implementa mediante StorageClass, PersistentVolume y PersistentVolumeClaim.

En el chart se deja elegir si se quiere almacenamiento dinámico (*pvc.dinamico* definido y *pvcExistente* vacío) o estático (*pvcExistente* definido).

En el almacenamiento estático, debe crearse desde fuera los tres elementos: StorageClass, PersistentVolume y PersistentVolumeClaim. Y al instalar,
en el parametro *pvcExistente* del values se indicara el nombre del PVC creado para que se pueda acceder desde el deployment/daemonset.

En el almacenamiento dinámico, sólo es necesario crear desde fuera un StorageClass con provisionador, y referenciarlo desde *pvc.dinamico.storageClassName*.
La instalación del chart crea un PVC, que a su vez hace uso del provisionador para crear automáticamente un PV.

El PVC, ya sea estático o dinámico, es usado por todos los PODs de gencdr+transcdr y también por los PODs de enviokafka

El volumen persistente puede ser local o remoto; pero hay que tener en cuenta que los volumenes locales no sobreviven a una caida del cluster o del nodo worker,
con lo que en un entorno de producción se recomienda siempre tener volumenes remotos.

La configuración más sencilla de este almacenamiento persistente podría ser usando directorios locales en los nodos worker (no
recomendable en entornos que no sean de desarrollo o de pruebas).
Para ello habría que crear un directorio (por ejemplo /gencdr) en cada uno de los nodos worker y darle permisos de escritura para el
grupo 0. Y a continuación crear los objetos kubernetes que lo referencian (en el siguiente ejemplo el PV referencia
el directorio /gencdr de los nodos worker1 y worker2).

````
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gencdr
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain

---

apiVersion: v1
kind: PersistentVolume
metadata:
  name: gencdr-pv
  labels:
    type: local
spec:
  storageClassName: gencdr
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteOnce
  local:
    path: "/gencdr"
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - worker1
          - worker2

----

apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: staticgencdr-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: gencdr

````

### Envío al SG

El envío del transcdr al SG se puede hacer de dos formas.

Si se desea un envío a un proceso de una IP, se deben configurar los parametros *transcdr.procRecepcionCDRs* y *transcdr.ipRecepcionCDRs*. Este mecanismo requiere además que esté desactivado el parámetro de cnf DISTRIBUCION_REPARTO (es la configuración
por defecto incluida en la imagen del contenedor).

Si se desea un envio a un servicio, se debe configurar dicho servicio en el parámetro de cnf DISTRIBUCION_REPARTO.

### Envío a Kafka

Los CDRs se van agrupando en ficheros del directorio GENERADOS. Una vez que se alcanza un umbral (de tiempo o de tamaño) esos ficheros se envían al SG
usando el transcdr, y una vez enviados se mueven al directorio TRANSMITIDOS.
Es posible definir un paso adicional para que estos ficheros transmitidos se envíen también a un bus Kafka. Para ello hay tener un servidor Kafka al que se
pueda acceder desde los PODs y deben estar creados los topics a los que se mandan los ficheros. Los parámetros a configurar en el values son los
definidos como kafka ( Ver [ Configuración ](#configuración)  )

Por cada elemento definido en *kafka.replicas* se levantará un contenedor que envía a Kafka los ficheros del directorio *dirIN* y una vez confirmado el envío, los
mueve al directorio *dirOUT*. Para que un fichero se procese debe llevar sin accederse más de *tmoutActivo* segundos. El fichero se envía al broker kafka *broker*
y al tópico *topic*. En *maxBytes* debe definirse el tamaño máximo que puede tomar un fichero de CDRs.

### Limitación de recursos

Al instalar deben particularizarse los límites (resources del fichero values) de los procesos gencdr y transcdr .
Se deben configurar tanto los límites de cpu como los de memoria. Por ejemplo:
````
resources:
  limits:
    cpu: "800m"
    memory: "10Mi"
````

1000m de cpu es una CPU. Dado que los procesos de altamira son mono-thread, no tiene sentido definir límites mayores que dicho valor.
1Mi de memoria es 1024*1024 bytes. El límite que se defina para la memoria debe ser un valor que el proceso no vaya a alcanzar nunca
en un funcionamiento normal, ya que si lo alcanza se le reiniciará.

Si se desea, además de los límites se puede definir la cantidad reservada (*resources.requests*). En caso de definirse *limits*; pero no *requests*, se
considera que el valor de requests es identico al de limits. Cuando todos los contenedores de un POD tienen los mismos valores de requests y limits
se considera que dicho POD tiene una calidad de servicio garantizada y no se le reiniciara en escenarios de sobrecarga del nodo.

El valor de requests se utiliza para determinar en que nodo se despliega el pod. Además, el valor de *resources.requests.memory* se usa también para
calcular el orden de eliminación de procesos en escenarios de sobrecarga del nodo. La probabilidad de que un proceso sea matado en estos
escenarios es mayor cuanto menor sea su *resources.requests.memory*.

Por tanto, la recomendación es que se definan limits y requests superiores a lo que pueda necesitar el proceso en un funcionamiento normal.
En el caso de procesos que sea particularmente importante que no sean reiniciados se debe definir sólo limits (que es equivalente a definir
request y limits con el mismo valor).

### Capabilities

En la instalación se incluye un *containerSecurityContext* por defecto preparado para entornos de pruebas, en los que se requieren
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

La imagen de gencdr incluye varios mecanismos para la depuración en tiempo de ejecución:
* Se han instalado varias herramientas que pueden ser necesarias a la hora de analizar problemas: ping, curl, tcpdump, pstack, gdb, traceroute, sqlplus
* Si se define en la instalación el parámetro env.SLEEP_AL_TERMINAR, el contenedor no se cerrara aunque se muera el proceso y las sondas darán OK
* En caso de querer depurar un contenedor que ya está corriendo, se puede crear un fichero vacío /export/manager/DEBUG. Mientras exista este fichero,
  el contenedor no se cerrará aunque se muera el proceso y las sondas darán OK
* El mecanismos de cambio de nivel de trazas en caliente sólo aplica a procesos nemesis, con lo que no esá disponible para gencdr ni para transcdr.

### Métricas

Las métricas que generan los procesos gencdr y transcdr del POD se exportan en el puerto 9100, en la URL /metrics.
La métricas de ambos procesos se entregan juntas en la misma URL. Son las siguientes:

*  altamira_cnt_gencdr_total. Métrica de tipo counter, que se corresponde con los contadores tradicionales de AltamirA para el proceso gencdr
   Se usan las etiquetas 'id' para el número de contador, y 'desc' para un nombre descriptivo del contador.  Por ejemplo
   ````
   altamira_cnt_gencdr_total{id="0000000",desc="CDRsRecibidos"}
   ````
*  altamira_alrm_gencdr_total. Métrica de tipo counter, que se corresponde con las alarmas tradicionales de AltamirA para el proceso gencdr.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_alrm_gencdr_total{id="ALR0010101",desc="Ocupacion leve del disco de CDRsa"}
   ````
*  altamira_cesable_gencdr. Métrica de tipo gauge, que se corresponde con alarmas cesables activas para el proceso gencdr.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_cesable_gencdr{id="ALR0012038",desc="Gencdr equipado por superar el numero de ficheros disponible en el directorio de CDRs"}
   ````
*  altamira_cnt_transcdr_total. Métrica de tipo counter, que se corresponde con los contadores tradicionales de AltamirA para el proceso transcdr.
   Se usan las etiquetas 'id' para el número de contador, y 'desc' para un nombre descriptivo del contador.
   El proceso transcdr no tiene contadores, con lo que tampoco se va a generar nunca esta métrica.
*  altamira_alrm_transcdr_total. Métrica de tipo counter, que se corresponde con las alarmas tradicionales de AltamirA para el proceso transcdr.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma. Por ejemplo
   ````
   altamira_alrm_trans_total{id="ALR0011034",desc="Error de comunicacion con el agente remoto de ficheros del SG"}
   ````
*  altamira_cesable_transcdr. Métrica de tipo gauge, que se corresponde con alarmas cesables activas para el proceso transcdr.
   Se usan las etiquetas 'id' para el número de alarma precedido del prefijo ALR, y 'desc' para el texto de la alarma.
   El proceso transcdr no tiene alarmas cesables, con lo que tampoco se va a generar nunca esta métrica

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
* Debe existir el namespace en que se vaya a instalar gencdr
* En el namespace en que se vaya a instalar tiene que existir un Secret de nombre oracle-secret con la configuración de acceso a oracle
* En el namespace en que se vaya a instalar tiene que existir un Secret de nombre zmq-secret con la configuración de cifrado de comunicaciones para 0MQ
* En la BD del SDP
  * La tabla ZMQC_CONEXIONES debe existir y estar configurada con las nuevas conexiones 0MQ:
    * GENCDR -> TRANSCDR, con NUTIPOENVIO=2 y NUDIRCONEXION=0
  * La tabla ZMQA_ACTIVOS tiene que existir y tener la columna ZMQA_CDWORKER. Esta columna se ha añadido en un parche posterior a la creación de la tabla
    y es necesaria para esta versión

* Las imagenes de gencdr+transcdr, enviokafka y metrics_aa_exporter deben estar subidas al repositorio del cluster. Dichas images se entregan como ficheros tgz.
* Debe estar creado un StorageClass de nombre gencdr. Si se usa almacenamiento estático, también deben estar creados PV y PVC referenciando a ese StorageClass.
  Si se usa almacenamiento dinámico, el StorageClass debe tener un provisionador que cree el PV.
  El PersistentVolume debe tener suficiente espacio libre como para guardar los CDRs que se generen.
  No hay un mecanismo de purgado definido sobre este sistema de ficheros. Debera implementarse
  por fuera o asignar el suficiente espacio como para asegurar que nunca se llena.
* Si se desea enviar los ficheros de CDR a kafka (parámetro *kafka.envio*), tiene que existir un servidor kafka y estar accesible desde los PODs. Los topics
  a los que se desea enviar los ficheros de CDRs deben estar creados y deben admitir mensajes del tamaño máximo de fichero que pueda generar el gencdr

## Instalacion

El chart se entrega comprimido en un fichero tgz. Si se desea, seria posible subir dicho fichero tgz a un servidor HTTP que haga de repositorio de charts e instalarlo desde alli. La otra posibilidad es instalar directamente desde el fichero, que es la que se detalla en este documento

* Como primer paso, generar un fichero con los values sobre el que podremos modificar los parametros que queramos
	````
	helm show values gencdr-13.3.1-0.tgz > values-gencdr-13.3.1-0.yaml
	````
* Modificar el fichero generado, particularizando los parametros que nos interesan.
Si no nos interesa modificar algún parámetro, lo podemos eliminar. Y si no queremos cambiar ningún parámetro de un objeto, podemos borrar el objeto completo. Los parámetros mas relevantes a revisar son los siguientes (el detalle de cada uno puede verse en el apartado de [ Configuración ](#configuración)  )
  * despliegueDaemonset
  * replicasDeployment
  * instancias
  * **containerSecurityContext**: En entornos productivos que requieran una mayor seguridad, quitar todas las capabilities y no reactivar ninguna
  * env.NIVEL_TRAZAS
  * env.CNF_OPENTELEMETRY_EXPORTER_TIPO
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * env.CNF_OPENTELEMETRY_EXPORTER_HOST
  * **env.CNF_ZMQ_CIFRADO**
  * **env.DATABASE_ENCRYPT**
  * **gencdr.image.repository**: Hay que definirlo obligatoriamente
  * **transcd.image.repository**: Hay que definirlo obligatoriamente
  * **exporterImage.repository**: Hay que definirlo obligatoriamente
  * **kafka.image.repository**: Hay que definirlo obligatoriamente
  * **transcdr.procRecepcionCDRs**: Hay que definirlo obligatoriamente, a menos que se este usando DISTRIBUCION_REPARTO
  * **transcdr.ipRecepcionCDRs**: Hay que definirlo obligatoriamente,  a menos que se este usando DISTRIBUCION_REPARTO
  * persistentVolume.className
  * persistentVolume.size
* Instalar el chart con las particularizaciones que se hayan definido en el fichero *values-gencdr-13.3.1-0.yaml*.  
El \<namespace\> se recomienda que incluya el id del SDP con que se comunican los procesos y el nombre del servicio (por ejemplo aa-ocs-prepago1). Como \<release name\> se usa uno descriptivo de lo que se esta instalando, como *cdrs*

	````
	helm install -n <namespace>  <release name> gencdr-13.3.1-0.tgz -f values-gencdr-13.3.1-0.yaml
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
| despliegueDaemonset | bool | `true` | Indica si se despliega como daemonset o como deployment |
| env.CNF_OPENTELEMETRY_EXPORTER_HOST | object | `{"value":"jaeger-agent.jaeger"}` | Host donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_PORT) Si es por UDP, se suele enviar a localhost o a un DaemonSet (indicando en CNF_OPENTELEMETRY_EXPORTER_HOST status.hostIP) Si es por HTTP se pone la direccion del jaeger agent, por ejemplo jaeger-agent.jaeger |
| env.CNF_OPENTELEMETRY_EXPORTER_PORT | object | `{"value":"6831"}` | Puerto donde se envian los intervalos de OpenTelemetry (en conjuncion con CNF_OPENTELEMETRY_EXPORTER_HOST) |
| env.CNF_OPENTELEMETRY_EXPORTER_TIPO | object | `{"value":"0"}` | Tipo de exporter de OpenTelemetry.  0-Ninguno, 1-Logs, 2-JaegerUDP, 3-JaegerHTTP |
| env.CNF_TRATAMIENTO_SIGTERM_CLOUD | object | `{"value":"2"}` | Tratamiento ante SIGTERM. 0-para, 2-indisponible y continua procesando lo que haya pendiente |
| env.CNF_ZMQ_CIFRADO | object | `{"value":"1"}` | Uso de cifrado en las conexiones 0MQ (las claves deben proporcionarse en el zmq-secret). Los procesos    de FED y BELS tienen que tener la misma configuración |
| env.CNF_ZMQ_UMBRAL_ENVIO_MISMO_NODO | object | `{"value":"0"}` | Numero de instancias de un servidor que debe haber en tu mismo nodo para activar el envio solo a instancias de     tu mismo nodo worker (0 para desactivar la funcionalidad) |
| env.DATABASE_ENCRYPT | object | `{"value":"1"}` | Variable para definir si la comunicacion con la BD se hace encriptada o no. Valor 0 indica no encriptada, valor 1 encriptada. |
| env.NIVEL_TRAZAS | object | `{"value":"0"}` | Nivel de trazas del proceso: 0-Todas. 1-Solo de error e informativas |
| exporterImage.repository | string | `"zape-k8s-dockreg:5000/metrics_aa_exporter"` | Repositorio de donde bajar el contenedor del exportador de metricas, para llevar los contadores del proceso prometheus |
| gencdr.funcionalidad | string | `"GENCDR"` | Funcionalidad para gencdr (nombre) |
| gencdr.funcionalidadId | string | `"29"` | Funcionalidad para gencdr (id) |
| gencdr.image.repository | string | `"zape-k8s-dockreg:5000/gencdr"` | Repositorio de donde bajar el contenedor del gencdr  |
| gencdr.resources | string | `nil` |  |
| instancias | int | `1` | Numero de instancias de gencdr y transcdr dentro de cada POD. Aplica tanto a daemonset como a deployment |
| kafka.envio | bool | `false` | Activa el envio de ficheros de CDR a kafka |
| kafka.image.repository | string | `"zape-k8s-dockreg:5000/enviokafka"` | Repositorio de donde bajar el contenedor del enviokafka |
| kafka.replicas.hotbilling.broker | string | `"kafka-headless.default"` | Broker kafka al que enviar los ficheros de CDRs |
| kafka.replicas.hotbilling.dirIN | string | `"CDR_SG/TRANSMITIDOS/HOTBILLING"` | Directorio del volumen de CDRs que se envia a Kafka (si se mandan al SG, deberia ser TRANSMITIDOS) |
| kafka.replicas.hotbilling.dirOUT | string | `"CDR_SG/TRANSMITIDOSKAFKA/HOTBILLING"` | Directorio del volumen de CDRs donde se mueven los ficheros tras su envio a Kafka |
| kafka.replicas.hotbilling.maxBytes | string | `"10000000"` | Tamaño maximo del fichero que se puede enviar. Debe coincidir con lo que se haya configurado en kafka, en el topic    y en el tamaño que maneja el GENCDR |
| kafka.replicas.hotbilling.tmoutActivo | int | `60` | Temporizador para considerar un fichero activo (y no enviarlo a Kafka) |
| kafka.replicas.hotbilling.topic | string | `"cdrshb"` | Topico kafka al que enviar los ficheros de CDRs |
| kafka.replicas.normal.broker | string | `"kafka-headless.default"` | Broker kafka al que enviar los ficheros de CDRs |
| kafka.replicas.normal.dirIN | string | `"CDR_SG/TRANSMITIDOS/NORMAL"` | Directorio del volumen de CDRs que se envia a Kafka (si se mandan al SG, deberia ser TRANSMITIDOS) |
| kafka.replicas.normal.dirOUT | string | `"CDR_SG/TRANSMITIDOSKAFKA/NORMAL"` | Directorio del volumen de CDRs donde se mueven los ficheros tras su envio a Kafka |
| kafka.replicas.normal.maxBytes | string | `"10000000"` | Tamaño maximo del fichero que se puede enviar. Debe coincidir con lo que se haya configurado en kafka, en el topic    y en el tamaño que maneja el GENCDR |
| kafka.replicas.normal.tmoutActivo | int | `60` | Temporizador para considerar un fichero activo (y no enviarlo a Kafka) |
| kafka.replicas.normal.topic | string | `"cdrs"` | Topico kafka al que enviar los ficheros de CDRs |
| kafka.resources | string | `nil` |  |
| podAnnotations."prometheus.io/port" | string | `"9100"` | Puerto donde se sirven las metricas |
| podAnnotations."prometheus.io/scrape" | string | `"true"` | Anotacion para indicar a prometheus que debe recopilar metricas de estos pods |
| pvc.dinamico.accessMode | string | `"ReadWriteOnce"` |  |
| pvc.dinamico.retain | bool | `true` |  |
| pvc.dinamico.size | string | `"100Gi"` | Tamaño de disco que se va a solicitar en el PVC para los ficheros de CDRs |
| pvc.dinamico.storageClassName | string | `"gencdr"` | Nombre de la clase que proporciona el PV al gencdr |
| pvc.pvcExistente | string | `nil` | Nombre del PVC precreado externamente. Si se deja vacio se asume dinamico y el PVC será creado en la instalacion del chart. |
| replicasDeployment | int | `1` | Numero de PODS gencdr+transcdr en un despliegue Deployment. En un despliegue daemonset se levanta un POD por nodo    En un despliegue de tipo deployment se levantan &lt;replicasDeployment&gt; PODs repartidos entre los nodos, cada uno con &lt;instancias&gt; instancias    La relacion gencdr-transcdr es 1-1 con lo que siempre se despliegan los mismos trans que gen |
| transcdr.funcionalidad | string | `"TRANSCDR"` | Funcionalidad para transcdr (nombre) |
| transcdr.funcionalidadId | string | `"30"` | Funcionalidad para transcdr (id) |
| transcdr.image.repository | string | `"zape-k8s-dockreg:5000/transcdr"` | Repositorio de donde bajar el contenedor del transcdr |
| transcdr.ipRecepcionCDRs | string | `"127.0.0.1"` | IP a la que se envian los CDRs cuando DISTRIBUCION_REPARTO esta desactivada |
| transcdr.procRecepcionCDRs | string | `"RCVCDR"` | Proceso al que se envían los CDRs cuando DISTRIBUCION_REPARTO esta desactivado |
| transcdr.resources | string | `nil` |  |
| transcdr.tamBloque | int | `10000` | Tamaño de bloque de envio |
