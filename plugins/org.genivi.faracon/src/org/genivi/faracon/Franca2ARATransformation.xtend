package org.genivi.faracon

import autosar40.autosartoplevelstructure.AUTOSAR
import autosar40.commonstructure.implementationdatatypes.ImplementationDataType
import autosar40.genericstructure.generaltemplateclasses.arpackage.ARPackage
import autosar40.genericstructure.generaltemplateclasses.primitivetypes.ArgumentDirectionEnum
import java.util.Set
import javax.inject.Inject
import javax.inject.Singleton
import org.franca.core.franca.FArgument
import org.franca.core.franca.FAttribute
import org.franca.core.franca.FBroadcast
import org.franca.core.franca.FEnumerationType
import org.franca.core.franca.FInterface
import org.franca.core.franca.FMethod
import org.franca.core.franca.FModel
import org.franca.core.franca.FType
import org.franca.core.franca.FTypeCollection
import org.genivi.faracon.franca2ara.ARAModelSkeletonCreator
import org.genivi.faracon.franca2ara.ARANamespaceCreator
import org.genivi.faracon.franca2ara.ARAPrimitveTypesCreator
import org.genivi.faracon.franca2ara.ARATypeCreator
import org.genivi.faracon.franca2ara.AutosarAnnotator
import org.genivi.faracon.names.FrancaNamesCollector
import org.genivi.faracon.names.NamesHierarchy

import static org.franca.core.framework.FrancaHelpers.*

import static extension org.franca.core.FrancaModelExtensions.*

@Singleton
class Franca2ARATransformation extends Franca2ARABase {

	@Inject
	var extension ARAPrimitveTypesCreator aRAPrimitveTypesCreator
	@Inject
	var extension ARATypeCreator araTypeCreator
	@Inject
	var extension ARAModelSkeletonCreator araModelSkeletonCreator
	@Inject
	var extension ARANamespaceCreator
	@Inject
	var extension AutosarAnnotator

	@Inject
	NamesHierarchy namesHierarchy

	var Set<FType> allNonPrimitiveElementTypesOfAnonymousArrays

	static final String ANNOTATION_LABEL_ORIGINAL_PARENT_INTERFACE = "OriginalParentInterface"
	static final String ANNOTATION_LABEL_ARTIFICAL_EVENT_DATA_STRUCT_TYPE = "ArtificalEventDataStructType"

	def setAllNonPrimitiveElementTypesOfAnonymousArrays (Set<FType> allNonPrimitiveElementTypesOfAnonymousArrays) {
		this.allNonPrimitiveElementTypesOfAnonymousArrays = allNonPrimitiveElementTypesOfAnonymousArrays
	}

	def AUTOSAR transform(FModel src) {
		// Fill all names of the Franca model into a hierarchy of names.
		namesHierarchy.clear();
		val FrancaNamesCollector francaNamesCollector = new FrancaNamesCollector
		francaNamesCollector.fillNamesHierarchy(src, namesHierarchy)

		// Process the conversion.
		createPrimitiveTypesPackage(null)
		// we are intentionally not adding the primitive types to the AUTOSAR target model
		// arPackages.add(createPrimitiveTypesPackage)

		val AUTOSAR aModel = src.createAutosarModelSkeleton
		val elementPackage = src.accordingArPackage
		elementPackage.elements.addAll(src.interfaces.map[transform(elementPackage)])
		
		src.typeCollections.forEach[it.transform]

		aModel
	}

	def create fac.createServiceInterface transform(FInterface src, ARPackage targetPackage) {
		if (!src.managedInterfaces.empty) {
			getLogger.logError("The manages relation(s) of interface " + src.name + " cannot be converted! (IDL1280)")
		}
		shortName = src.name

		val targetPackageWithVersion = src.createPackageForVersion(targetPackage)
		targetPackageWithVersion.elements += it

		namespaces.addAll(targetPackageWithVersion.createNamespaceForPackage)
		events.addAll(getAllBroadcasts(src).map[it.transform(src, targetPackageWithVersion)])
		fields.addAll(getAllAttributes(src).map[it.transform(src)])
		methods.addAll(getAllMethods(src).map[it.transform(src)])
		
		// Ensure that all local type definitions of the interface definition are translated
		// even if they are not referenced.
		transform(src)
	}
	
	def void transform(FTypeCollection fTypeCollection){
		val types = fTypeCollection.types.map[dataTypeForReference]
		val accordingArPackage = fTypeCollection.accordingArPackage

        val parentPackage = typeCollection.createPackageForVersion(accordingArPackage)

		// Add the conversions of all Franca types that are defined in this type collection.
		parentPackage?.elements?.addAll(types)

		// Add the according CompuMethods for all Franca enumeration types of this type collection.
		parentPackage?.elements?.addAll(
			fTypeCollection.types.filter(FEnumerationType).map[createCompuMethod]
		)

		// Add artificial vector type definitions for all types of this type collection
		// which are used as element type of an anonymous array anywhere in the any Franca input model.
		parentPackage?.elements?.addAll(
			fTypeCollection.types.filter[allNonPrimitiveElementTypesOfAnonymousArrays?.contains(it)].map[fType|
				createArtificialVectorType(fType)
			]
		)		
	}

	// Beside the original parent interface check, the parameter 'parentInterface' is important
	// in case of emulation of interface inheritance.
	// As methods are copied to derived interfaces multiple copies of them are needed.
	// Without the parameter 'parentInterface', the memoisation mechanism of Xtend create methods would avoid this.
	def create fac.createClientServerOperation transform(FMethod src, FInterface parentInterface) {
		shortName = src.name

		// The flag that indicates a fire&forget method is an optional member in AUTOSAR models.
		// It can have the values {true, false, undefined}. We encode non-fire&forget methods with 'undefined'.
		// An additional command line option might give the user the choice between encoding 
		// with 'false' or 'undefined' in this case.
		if (src.fireAndForget) {
			fireAndForget = true
		}

		arguments.addAll(src.inArgs.map[transform(true, parentInterface)])
		arguments.addAll(src.outArgs.map[transform(false, parentInterface)])

		// The Franca specific mechanism for the handling of method errors cannot be translated
		// because it is not compatible with the method errors mechanism of AUTOSAR,
		// at least in the serialization format of the method reply messages.
		if (src.errors !== null || src.errorEnum !== null) {
			getLogger.logError("The error enumeration of the method '" + src.name + "' in the namespace '" + src.model.name + '.' + src.interface
				+ "' cannot be translated into an AUTOSAR representation. "
				+ "At least the SOME/IP serialization formats would be incompatible. "
				+ "Implement your method error reporting based on user defined types instead!")
		}

		// If the method is not a direct member of the current interface definition but is inherited from
		// a direct or indirect base interface the original interface where it comes from is annotated.
		// As interface inheritance cannot be directly mapped to an AUTOSAR representation
		// this annotation provides the required information to reconstruct the original Franca model
		// uniquely from the AUTOSAR model.
		val FInterface originalParentInterface = src.getInterface
		if (parentInterface !== originalParentInterface) {
			it.addAnnotation(ANNOTATION_LABEL_ORIGINAL_PARENT_INTERFACE,
				originalParentInterface.getARFullyQualifiedName)
		}
	}

	// The parameter 'parentInterface' is important in case of emulation of interface inheritance.
	// As methods are copied to derived interfaces multiple copies of the method arguments are needed as well.
	// Without the parameter 'parentInterface', the memoisation mechanism of Xtend create methods would avoid this.
	def create fac.createArgumentDataPrototype transform(FArgument arg, boolean isIn, FInterface parentInterface) {
		shortName = arg.name
		// category = xxx
		type = createDataTypeReference(arg.type, arg)
		direction = if(isIn) ArgumentDirectionEnum.IN else ArgumentDirectionEnum.OUT
	}

	// Beside the original parent interface check, the parameter 'parentInterface' is important
	// in case of emulation of interface inheritance.
	// As attributes are copied to derived interfaces multiple copies of them are needed.
	// Without the parameter 'parentInterface', the memoisation mechanism of Xtend create methods would avoid this.
	def create fac.createField transform(FAttribute src, FInterface parentInterface) {
		shortName = src.name
		type = src.type.createDataTypeReference(src)
		hasGetter = !src.noRead
		hasNotifier = !src.noSubscriptions
		hasSetter = !src.readonly

		// If the attribute is not a direct member of the current interface definition but is inherited from
		// a direct or indirect base interface the original interface where it comes from is annotated.
		// As interface inheritance cannot be directly mapped to an AUTOSAR representation
		// this annotation provides the required information to reconstruct the original Franca model
		// uniquely from the AUTOSAR model.
		val FInterface originalParentInterface = src.interface
		if (parentInterface !== originalParentInterface) {
			it.addAnnotation(ANNOTATION_LABEL_ORIGINAL_PARENT_INTERFACE,
				originalParentInterface.getARFullyQualifiedName)
		}
	}

	// Beside the original parent interface check, the parameter 'parentInterface' is important
	// in case of emulation of interface inheritance.
	// As broadcasts are copied to derived interfaces multiple copies of them are needed.
	// Without the parameter 'parentInterface', the memoisation mechanism of Xtend create methods would avoid this.
	def create fac.createVariableDataPrototype transform(FBroadcast src, FInterface parentInterface,
		ARPackage interfaceArPackage) {
		shortName = src.name

		type = if (src?.outArgs.length == 1) {
			src.outArgs.get(0).type.createDataTypeReference(src.outArgs.get(0))
		} else {
			val ImplementationDataType artificalBroadcastStruct = fac.createImplementationDataType
			artificalBroadcastStruct.shortName = namesHierarchy.createAndInsertUniqueName(
				parentInterface.francaFullyQualifiedName,
				src.name.toFirstUpper + "Data",
				FType
			)
			artificalBroadcastStruct.category = "STRUCTURE"
			val typeRefs = src.outArgs.map [
				it.createImplementationDataTypeElement(null)
			]
			artificalBroadcastStruct.subElements.addAll(typeRefs)
			artificalBroadcastStruct.ARPackage = interfaceArPackage
			artificalBroadcastStruct.addAnnotation(
				ANNOTATION_LABEL_ARTIFICAL_EVENT_DATA_STRUCT_TYPE,
				"Referencing event definition: " + src.getARFullyQualifiedName
			)
			interfaceArPackage.elements += artificalBroadcastStruct
			artificalBroadcastStruct
		}

		// If the broadcast is not a direct member of the current interface definition but is inherited from
		// a direct or indirect base interface the original interface where it comes from is annotated.
		// As interface inheritance cannot be directly mapped to an AUTOSAR representation
		// this annotation provides the required information to reconstruct the original Franca model
		// uniquely from the AUTOSAR model.
		val FInterface originalParentInterface = src.interface
		if (parentInterface !== originalParentInterface) {
			it.addAnnotation(ANNOTATION_LABEL_ORIGINAL_PARENT_INTERFACE,
				originalParentInterface.getARFullyQualifiedName)
		}

		// Selective broadcasts are not representable in an AUTOSAR model.
		if (src.selective) {
			getLogger.logError("The broadcast '" + originalParentInterface.name + "." + src.name +
				"' cannot be properly converted because selective broadcasts are not representable in an AUTOSAR model! (IDL1390)")
		}

		// Broadcast selectors are not representable in an AUTOSAR model.
		if (!src.selector.isNullOrEmpty) {
			getLogger.logError("The broadcast '" + originalParentInterface.name + "." + src.name +
				"' cannot be properly converted because broadcast selectors are not representable in an AUTOSAR model! (IDL1400)")
		}
	}

	static def String getARFullyQualifiedName(FInterface ^interface) {
		val FModel model = ^interface.getModel;
		(if(!model?.name.nullOrEmpty) "/" + model.name.replace('.', '/') else "") + "/" + ^interface?.name
	}

	static def String getARFullyQualifiedName(FBroadcast broadcast) {
		(broadcast.eContainer as FInterface).getARFullyQualifiedName + "/" + broadcast.name
	}

	static def String getFrancaFullyQualifiedName(FInterface ^interface) {
		val FModel model = ^interface.getModel;
		val modelPart = if(model !== null && !model.name.nullOrEmpty) model.name + "." else ""
		val interfacePart = if(interface !== null && !interface.name.nullOrEmpty) interface.name else ""
		return modelPart + interfacePart
	}

}
