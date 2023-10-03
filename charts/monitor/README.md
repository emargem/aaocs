# monitor

Version: 0.1.1
AppVersion: latest

Helm Chart para instalar en un cluster kubernetes el proceso monitor.

## Descripción

Este chart instala el proceso monitor para un único SDP. En caso de tenerse varios SDP, habra que
instalarlo más de una vez, particularizando la ifformación de conexión a la BD y el *namespace* en que se tnstala.

### Estructura del contenedor de monitor de relecturas

El POD de monitor se compone de un unico contenedor llamado reload-monitor.

Este proceso está comprobando periódicameete las fechas el las que se modificarodeterminadas tablas de la BD (tabla FCT_FECHACAMBIOTABLA) y las fechas en las que los procesos releyeron sus grupos de relectura (tabla FLG_FECHALECTURAGRUPO).
En caso de haberse modificado una tabla y que algú proceso no haya releído el grupo de relectura asociado, se genera en el monitor una m�rica de tipo GAUGE indicándol.

## Prerequisitos de instalación

* Kubernetes >= 1.14
* El usuario con que se administra el cluster (uso del comando kubectl) debe tener en el PATH la herramienta jq, para el parseo de JSON
* Si se desea usar la funcionalidad de OpenTelemetry, debe tenerse instalado el jaeger-agent. En funcion de que se tenga como un sidecar autoinyectado, como un daemonset o como un servicio, asi se tendran que configurar las variables CNF_OPENTELEMETRY_EXPORTER
* Helm >= 3
* Conexion con la BD del SDP. Debe obtenerse el fichero tnsnames.ora que define las conexiones con la base de datos. Este fichero puede obtenerse de uno de los FED tradicionales. Desde el cluster de kubernetes se debe poder acceder a las direcciones de cada conexion con la BD que se indica en dicho fichero.
* En la BD del SDP
  * La tabla ZMQA_ACTIVOS debe existir y en ella deben aparecer todos los procesos DIAMETAR3GPP y SERVERMSISM de ese SDP (esto indica que se ha instalado la nueva version de los procesos compatible con clientes en cloud, y que los procesos se han reiniciado despues de la configuracion de las variables en el cnf)
  * Las tablas relacionadas con relecturas: FLG_FECHALECTURAGRUPO y FCT_FECHACAMBIOTABLA, deben existir.
* Las imagenes de base y monitor_relecturas deben estar subidas al repositorio del cluster. Dichas images se entregan como ficheros tgz.
* Debe crearse el namespace y los secrets antes de instalar el chart.

## Instalacion

El chart se entrega comprimido en un fichero tgz. Si se desea, seria posible subir dicho fichero tgz a un servidor HTTP que haga de repositorio de charts e instalarlo desde alli. La otra posibilidad es instalar directamente desde el fichero, que es la que se detalla en este documento

* Como primer paso, generar un fichero con los values sobre el que podremos modificar los parametros que queramos
	````
	helm show values monitor-0.1.1.tgz > values-monitor-0.1.1.yaml
	````
* Modificar el fichero generado, particularizando los parametros que nos interesan.
Si no nos interesa modificar algún parámetro, lo podemos eliminar. Y si no queremos cambiar ningún parámetro de un objeto, podemos bo el objeto completo.
* Instalar el chart con las particularizaciones que se hayan definido en el fichero *values-monitor.yaml*.  
	````
	helm install -n <namespace> <release name> monitor-0.1.1.tgz -f values-monitor-0.1.1.yaml
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
| reloadMonitorImage.repository | string | `"zape-k8s-dockreg:5000/monitor_relecturas"` | Repositorio de donde bajar el monitor de relecturas |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |

